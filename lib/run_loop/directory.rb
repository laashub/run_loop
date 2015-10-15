module RunLoop

  # Class for performing operations on directories.
  class Directory
    require 'digest'
    require 'openssl'
    require 'pathname'

    # Dir.glob ignores files that start with '.', but we often need to find
    # dotted files and directories.
    #
    # Ruby 2.* does the right thing by ignoring '..' and '.'.
    #
    # Ruby < 2.0 includes '..' and '.' in results which causes problems for some
    # of run-loop's internal methods.  In particular `reset_app_sandbox`.
    def self.recursive_glob_for_entries(base_dir)
      Dir.glob("#{base_dir}/{**/.*,**/*}").select do |entry|
        !(entry.end_with?('..') || entry.end_with?('.'))
      end
    end

    # Computes the digest of directory.
    #
    # @param path A path to a directory.
    # @raise ArgumentError When `path` is not a directory or path does not exist.
    def self.directory_digest(path)

      unless File.exist?(path)
        raise ArgumentError, "Expected '#{path}' to exist"
      end

      unless File.directory?(path)
        raise ArgumentError, "Expected '#{path}' to be a directory"
      end

      entries = self.recursive_glob_for_entries(path)

      if entries.empty?
        raise ArgumentError, "Expected a non-empty dir at '#{path}' found '#{entries}'"
      end

      debug = RunLoop::Environment.debug?

      sha = OpenSSL::Digest::SHA256.new
      entries.each do |file|
        unless self.skip_file?(file, 'SHA1', debug)
          begin
            sha << File.read(file)
          rescue => e
            if debug
              RunLoop.log_warn(%Q{
RunLoop::Directory.directory_digest raised an error:

#{e}

while trying to find the SHA of this file:

#{file}

Please report this here:

https://github.com/calabash/run_loop/issues

})
            end
          end
        end
      end
      sha.hexdigest
    end

    def self.size(path, format)

      allowed_formats = [:bytes, :kb, :mb, :gb]
      unless allowed_formats.include?(format)
        raise ArgumentError, "Expected '#{format}' to be one of #{allowed_formats.join(', ')}"
      end

      unless File.exist?(path)
        raise ArgumentError, "Expected '#{path}' to exist"
      end

      unless File.directory?(path)
        raise ArgumentError, "Expected '#{path}' to be a directory"
      end

      entries = self.recursive_glob_for_entries(path)

      if entries.empty?
        raise ArgumentError, "Expected a non-empty dir at '#{path}' found '#{entries}'"
      end

      size = self.iterate_for_size(entries)

      case format
        when :bytes
          size
        when :kb
          size/1000.0
        when :mb
          size/1000.0/1000.0
        when :gb
          size/1000.0/1000.0/1000.0
        else
          # Not expected to reach this.
          size
      end
    end

    private

    def self.skip_file?(file, task, debug)
      skip = false
      if File.directory?(file)
        # Skip directories
        skip = true
      elsif !Pathname.new(file).exist?
        # Skip broken symlinks
        skip = true
      elsif !File.exist?(file)
        # Skip files that don't exist
        skip = true
      else
        case File.ftype(file)
          when 'fifo'
            RunLoop.log_warn("#{task} IS SKIPPING FIFO #{file}") if debug
            skip = true
          when 'socket'
            RunLoop.log_warn("#{task} IS SKIPPING SOCKET #{file}") if debug
            skip = true
          when 'characterSpecial'
            RunLoop.log_warn("#{task} IS SKIPPING CHAR SPECIAL #{file}") if debug
            skip = true
          when 'blockSpecial'
            skip = true
            RunLoop.log_warn("#{task} SKIPPING BLOCK SPECIAL #{file}") if debug
          else

        end
      end
      skip
    end

    def self.iterate_for_size(entries)
      debug = RunLoop::Environment.debug?
      size = 0
      entries.each do |file|
        unless self.skip_file?(file, "SIZE", debug)
          size = size + File.size(file)
        end
      end
      size
    end
  end
end
