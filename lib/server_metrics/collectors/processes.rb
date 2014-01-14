require 'sys/proctable'
require 'server_metrics/lib/proctable_lite' # used on linux
require 'server_metrics/system_info'

# Collects information on processes. Groups processes running under the same command, and sums up their CPU & memory usage.
# CPU is calculated **since the last run**, and is a pecentage of overall CPU usage during the time span since the instance was last run.
#
# FAQ:
#
# 1) top and htop show PIDs. Why doesn't this class? This class aggregates processes. So if you have 10 apache processes running, it will report the total memory and CPU for all instances, and also report that there are 10 processes.
#
# 2) why are the process CPU numbers lower than [top|htop]? We normalize the CPU usage according to the number of CPUs your server has. Top and htop don't do that. So on a 8 CPU system, you'd expect these numbers to be almost an order of magnitude lower.
#
# 
# http://www.linuxquestions.org/questions/linux-general-1/per-process-cpu-utilization-557577/
class ServerMetrics::Processes
  # most commmon - used if page size can't be retreived. units are bytes.
  DEFAULT_PAGE_SIZE = 4096 

  def initialize(options={})
    @last_run
    @last_jiffies
    @last_process_list
    @proc_table_klass = ServerMetrics::SystemInfo.os =~ /linux/ ? SysLite::ProcTable : Sys::ProcTable # this is used in calculate_processes. On Linux, use our optimized version
  end


  # This is the main method to call. It returns a hash of processes, keyed by the executable name.
  #
  # {'mysqld' =>
  #     {
  #      :cmd => "mysqld",    # the command (without the path of arguments being run)
  #      :count    => 1,      # the number of these processes (grouped by the above command)
  #      :cpu      => 34,     # the percentage of the total computational resources available (across all cores/CPU) that these processes are using.
  #      :memory   => 2,      # the percentage of total memory that these processes are using.
  #      :cmd_lines => ["cmd args1", "cmd args2"]
  #     },
  #  'apache' =>
  #     {
  #      ....
  #     }
  # }

  def run
    @processes = calculate_processes # returns a hash
    @processes.keys.inject(@processes) { |processes, key| processes[key][:cmd] = key; processes }
  end

  # called from run(). This method lists all the processes running on the server, groups them by command,
  # and calculates CPU time for each process. Since CPU time has to be calculated relative to the last sample,
  # the collector has to be run twice to get CPU data.
  def calculate_processes
    ## 1. get a list of all processes
    processes = @proc_table_klass.ps.map{|p| ServerMetrics::Processes::Process.new(p) } # our Process object adds a method some behavior

    ## 2. loop through each process and calculate the CPU time.
    # The CPU values returned by ProcTable are cumulative for the life of the process, which is not what we want.
    # So, we rely on @last_process_list to make this calculation. If a process wasn't around last time, we use it's cumulative CPU time so far, which will be accurate enough.
    now = Time.now
    current_jiffies = get_jiffies
    if @last_run && @last_jiffies && @last_process_list
      elapsed_time = now - @last_run # in seconds
      elapsed_jiffies = current_jiffies - @last_jiffies
      if elapsed_time >= 1
        processes.each do |p|
          if last_cpu = @last_process_list[p.pid]
            p.recent_cpu = p.combined_cpu - last_cpu
          else
            p.recent_cpu = p.combined_cpu # this process wasn't around last time, so just use the cumulative CPU time for its existence so far
          end
          # a) p.recent_cpu / elapsed_jiffies = the amount of CPU time this process has taken divided by the total "time slots" the CPU has available
          # b) * 100 ... this turns it into a percentage
          # b) / num_processors ... this normalizes for the the number of processors in the system, so it reflects the amount of CPU power avaiable as a whole
          p.recent_cpu_percentage = ((p.recent_cpu.to_f / elapsed_jiffies.to_f ) * 100.0) / num_processors.to_f
        end
      end
    end

    ## 3. group by command and aggregate the CPU
    grouped = {}
    processes.each do |proc|
      grouped[proc.comm] ||= {
          :cpu => 0,
          :memory => 0,
          :count => 0,
          :cmdlines => []
      }
      grouped[proc.comm][:count]    += 1
      grouped[proc.comm][:cpu]      += proc.recent_cpu_percentage || 0
      if proc.has?(:rss) # mac doesn't return rss. Mac returns 0 for memory usage
        # converted to MB from bytes
        grouped[proc.comm][:memory]   += (proc.rss.to_f*page_size) / 1024 / 1024
      end
      grouped[proc.comm][:cmdlines] << proc.cmdline if !grouped[proc.comm][:cmdlines].include?(proc.cmdline)
    end # processes.each

    # {pid => cpu_snapshot, pid2 => cpu_snapshot ...}
    processes_to_store = processes.inject(Hash.new) do |hash, proc|
      hash[proc.pid] = proc.combined_cpu
      hash
    end

    @last_process_list = processes_to_store
    @last_jiffies = current_jiffies
    @last_run = now

    grouped
  end

  # Relies on the /proc directory (/proc/timer_list). We need this because the process CPU utilization is measured in jiffies.
  # In order to calculate the process' % usage of total CPU resources, we need to know how many jiffies have passed.
  # Unfortunately, jiffies isn't a fixed value (it can vary between 100 and 250 per second), so we need to calculate it ourselves.
  #
  # if /proc/timer_list isn't available, fall back to the assumption of 100 jiffies/second (10 milliseconds/jiffy)
  def get_jiffies
    if File.exist?('/proc/timer_list')
      `cat /proc/timer_list`.match(/^jiffies: (\d+)$/)[1].to_i
    else
      (Time.now.to_f*100).to_i
    end
  end
  
  # Sys::ProcTable.ps returns +rss+ in pages, not in bytes. 
  # Returns the page size in bytes.
  def page_size
    @page_size ||= %x(getconf PAGESIZE).to_i
  rescue
    @page_size = DEFAULT_PAGE_SIZE
  end
  
  def num_processors
    @num_processors ||= ServerMetrics::SystemInfo.num_processors  
  end

  # for persisting to a file -- conforms to same basic API as the Collectors do.
  # why not just use marshall? This is a lot more manageable written to the Scout agent's history file.
  def to_hash
    {:last_run=>@last_run, :last_jiffies=>@last_jiffies, :last_process_list=>@last_process_list}
  end

  # for reinstantiating from a hash
  # why not just use marshall? this is a lot more manageable written to the Scout agent's history file.
  def self.from_hash(hash)
    p=new(hash[:options])
    p.instance_variable_set('@last_run', hash[:last_run])
    p.instance_variable_set('@last_jiffies', hash[:last_jiffies])
    p.instance_variable_set('@last_process_list', hash[:last_process_list])
    p
  end

  # a thin wrapper around Sys:ProcTable's ProcTableStruct. We're using it to add some fields and behavior.
  # Beyond what we're adding, it just passes through to its instance of ProcTableStruct
  class Process
    attr_accessor :recent_cpu, :recent_cpu_percentage # used to store the calculation of CPU since last sample
    def initialize(proctable_struct)
      @pts=proctable_struct
      @recent_cpu = 0
    end
    # because apparently respond_to doesn't work through method_missing
    def has?(method_name)
      @pts.respond_to?(method_name)
    end
    def combined_cpu
      # best thread I've seen on cutime vs utime & cstime vs stime: https://www.ruby-forum.com/topic/93176
      # * cutime and cstime include CPUusage of child processes
      # * utime and stime don't include CPU usage of child processes
      (utime || 0) + (stime || 0)  # utime and stime aren't available on mac. Result is %cpu is 0 on mac.
    end
    # delegate everything else to ProcTable::Struct
    def method_missing(sym, *args, &block)
      @pts.send sym, *args, &block
    end
  end
end
