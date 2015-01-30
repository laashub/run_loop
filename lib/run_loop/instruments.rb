module RunLoop

  # A class for interacting with the instruments command-line tool
  #
  # @note All instruments commands are run in the context of `xcrun`.
  class Instruments

    # Returns an Array of instruments process ids.
    #
    # @note The `block` parameter is included for legacy API and will be
    #  deprecated.  Replace your existing calls with with .each or .map.  The
    #  block argument makes this method hard to mock.
    # @return [Array<Integer>] An array of instruments process ids.
    def instruments_pids(&block)
      pids = pids_from_ps_output
      if block_given?
        pids.each do |pid|
          block.call(pid)
        end
      else
        pids
      end
    end

    # Are there any instruments processes running?
    # @return [Boolean] True if there is are any instruments processes running.
    def instruments_running?
      instruments_pids.count > 0
    end

    # Send a kill signal to any running `instruments` processes.
    #
    # Only one instruments process can be running at any one time.
    #
    # @param [RunLoop::XCTools] xcode_tools The Xcode tools to use to determine
    #  what version of Xcode is active.
    def kill_instruments(xcode_tools = RunLoop::XCTools.new)
      kill_signal = kill_signal xcode_tools
      instruments_pids.each do |pid|
        unless kill_instruments_process(pid, kill_signal)
          kill_instruments_process(pid, 'KILL')
        end
      end
    end

    # Is the Instruments.app running?
    #
    # If the Instruments.app is running, the instruments command line tool
    # cannot take control of applications.
    def instruments_app_running?
      ps_output = `ps x -o pid,comm | grep Instruments.app | grep -v grep`.strip
      if ps_output[/Instruments\.app/, 0]
        true
      else
        false
      end
    end

    # Spawn a new instruments process in the context of `xcrun` and detach.
    #
    # @param [String] automation_template The template instruments will use when
    #  launching the application.
    # @param [Hash] options The launch options.
    # @param [String] log_file The file to log to.
    # @return [Integer] Returns the process id of the instruments process.
    # @todo Do I need to enumerate the launch options in the docs?
    # @todo Should this raise errors?
    # @todo Is this jruby compatible?
    def spawn(automation_template, options, log_file)
      splat_args = spawn_arguments(automation_template, options)
      if ENV['DEBUG'] == '1'
        puts  "#{Time.now} xcrun #{splat_args.join(' ')} >& #{log_file}"
        $stdout.flush
      end
      pid = Process.spawn('xcrun', *splat_args, {:out => log_file, :err => log_file})
      Process.detach(pid)
      pid.to_i
    end

    private

    # @!visibility private
    # Parses the run-loop options hash into an array of arguments that can be
    # passed to `Process.spawn` to launch instruments.
    def spawn_arguments(automation_template, options)
      array = ['instruments']
      array << '-w'
      array << options[:udid]

      trace = options[:results_dir_trace]
      if trace
        array << '-D'
        array << trace
      end

      array << '-t'
      array << automation_template

      array << options[:bundle_dir_or_bundle_id]

      {
            'UIARESULTSPATH' => options[:results_dir],
            'UIASCRIPT' => options[:script]
      }.each do |key, value|
        array << '-e'
        array << key
        array << value
      end
      array + options.fetch(:args, [])
    end

    # Send `kill_signal` to instruments process with `pid`.
    #
    # @param [Integer] pid The process id of the instruments process.
    # @param [String] kill_signal The kill signal to send.
    # @return [Boolean] If the process was terminated, return true.
    def kill_instruments_process(pid, kill_signal)
      begin
        if ENV['DEBUG'] == '1'
          puts "Sending '#{kill_signal}' to instruments process '#{pid}'"
        end
        Process.kill(kill_signal, pid.to_i)
        # Don't wait.
        # We might not own this process and a WNOHANG would be a nop.
        # Process.wait(pid, Process::WNOHANG)
      rescue Errno::ESRCH
        if ENV['DEBUG'] == '1'
          puts "Process with pid '#{pid}' does not exist; nothing to do."
        end
        # Return early; there is no need to wait if the process does not exist.
        return true
      rescue Errno::EPERM
        if ENV['DEBUG'] == '1'
          puts "Cannot kill process '#{pid}' with '#{kill_signal}'; not a child of this process"
        end
      rescue SignalException => e
        raise e.message
      end

      if ENV['DEBUG'] == '1'
        puts "Waiting for instruments '#{pid}' to terminate"
      end
      wait_for_process_to_terminate(pid, {:timeout => 2.0})
    end

    # @!visibility private
    #
    # ```
    # $ ps x -o pid,command | grep -v grep | grep instruments
    # 98081 sh -c xcrun instruments -w "43be3f89d9587e9468c24672777ff6241bd91124" < args >
    # 98082 /Xcode/6.0.1/Xcode.app/Contents/Developer/usr/bin/instruments -w < args >
    # ```
    #
    # When run from run-loop (via rspec), expect this:
    #
    # ```
    # $ ps x -o pid,command | grep -v grep | grep instruments
    # 98082 /Xcode/6.0.1/Xcode.app/Contents/Developer/usr/bin/instruments -w < args >
    # ```
    FIND_PIDS_CMD = 'ps x -o pid,command | grep -v grep | grep instruments'

    # @!visibility private
    #
    # Executes `ps_cmd` to find instruments processes and returns the result.
    #
    # @param [String] ps_cmd The Unix ps command to execute to find instruments
    #  processes.
    # @return [String] A ps-style list of process details.  The details returned
    #  are controlled by the `ps_cmd`.
    def ps_for_instruments(ps_cmd=FIND_PIDS_CMD)
      `#{ps_cmd}`.strip
    end

    # @!visibility private
    # Is the process described an instruments process?
    #
    # @param [String] ps_details Details about a process as returned by `ps`
    # @return [Boolean] True if the details describe an instruments process.
    def is_instruments_process?(ps_details)
      return false if ps_details.nil?
      (ps_details[/\/usr\/bin\/instruments/, 0] or
            ps_details[/sh -c xcrun instruments/, 0]) != nil
    end

    # @!visibility private
    # Extracts an Array of integer process ids from the output of executing
    # the Unix `ps_cmd`.
    #
    # @param [String] ps_cmd The Unix `ps` command used to find instruments
    #  processes.
    # @return [Array<Integer>] An array of integer pids for instruments
    #  processes.  Returns an empty list if no instruments process are found.
    def pids_from_ps_output(ps_cmd=FIND_PIDS_CMD)
      ps_output = ps_for_instruments(ps_cmd)
      lines = ps_output.lines("\n").map { |line| line.strip }
      lines.map do |line|
        tokens = line.strip.split(' ').map { |token| token.strip }
        pid = tokens.fetch(0, nil)
        process_description = tokens[1..-1].join(' ')
        if is_instruments_process? process_description
          pid.to_i
        else
          nil
        end
      end.compact.sort
    end

    # @!visibility private
    # The kill signal should be sent to instruments.
    #
    # When testing against iOS 8, sending -9 or 'TERM' causes the ScriptAgent
    # process on the device to emit the following error until the device is
    # rebooted.
    #
    # ```
    # MobileGestaltHelper[909] <Error>: libMobileGestalt MobileGestalt.c:273: server_access_check denied access to question UniqueDeviceID for pid 796 
    # ScriptAgent[796] <Error>: libMobileGestalt MobileGestaltSupport.m:170: pid 796 (ScriptAgent) does not have sandbox access for re6Zb+zwFKJNlkQTUeT+/w and IS NOT appropriately entitled
    # ScriptAgent[703] <Error>: libMobileGestalt MobileGestalt.c:534: no access to UniqueDeviceID (see <rdar://problem/11744455>)
    # ```
    #
    # @see https://github.com/calabash/run_loop/issues/34
    #
    # @param [RunLoop::XCTools] xcode_tools The Xcode tools to use to determine
    #  what version of Xcode is active.
    # @return [String] Either 'QUIT' or 'TERM', depending on the Xcode
    #  version.
    def kill_signal(xcode_tools = RunLoop::XCTools.new)
      xcode_tools.xcode_version_gte_6? ? 'QUIT' : 'TERM'
    end

    # @!visibility private
    # Wait for Unix process with id `pid` to terminate.
    #
    # @param [Integer] pid The id of the process we are waiting on.
    # @param [Hash] options Values to control the behavior of this method.
    # @option options [Float] :timeout (2.0) How long to wait for the process to
    #  terminate.
    # @option options [Float] :interval (0.1) The polling interval.
    # @option options [Boolean] :raise_on_no_terminate (false) Should an error
    #  be raised if process does not terminate.
    # @raise [RuntimeError] If process does not terminate and
    #  options[:raise_on_no_terminate] is truthy.
    def wait_for_process_to_terminate(pid, options={})
      default_opts = {:timeout => 2.0,
                      :interval => 0.1,
                      :raise_on_no_terminate => false}
      merged_opts = default_opts.merge(options)

      process_alive = lambda {
        begin
          Process.kill(0, pid.to_i)
          true
        rescue Errno::ESRCH
          false
        rescue Errno::EPERM
          true
        end
      }

      now = Time.now
      poll_until = now + merged_opts[:timeout]
      delay = merged_opts[:interval]
      has_terminated = false
      while Time.now < poll_until
        has_terminated = !process_alive.call
        break if has_terminated
        sleep delay
      end

      if ENV['DEBUG'] == '1' or ENV['DEBUG_UNIX_CALLS'] == '1'
        puts "Waited for #{Time.now - now} seconds for instruments with '#{pid}' to terminate"
      end

      if merged_opts[:raise_on_no_terminate] and not has_terminated
        details = `ps -p #{pid} -o pid,comm | grep #{pid}`.strip
        raise RuntimeError, "Waited #{merged_opts[:timeout]} seconds for process '#{details}' to terminate"
      end
      has_terminated
    end
  end
end
