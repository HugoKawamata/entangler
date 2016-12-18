require_relative 'background/master'

module Entangler
  module Executor
    class Master < Base
      include Entangler::Executor::Background::Master

      def run
        perform_initial_rsync
        sleep 1
        start_remote_slave
        super
        @remote_writer.close
        @remote_reader.close
      end

      private

      def validate_opts
        super
        if @opts[:remote_mode]
          @opts[:remote_port] ||= '22'
          validate_remote_opts
        else
          validate_local_opts
        end
      end

      def validate_local_opts
        @opts[:remote_base_dir] = File.realpath(File.expand_path(@opts[:remote_base_dir]))
        raise "Destination directory can't be the same as the base directory" if @opts[:remote_base_dir] == base_dir
        raise "Destination directory doesn't exist" unless Dir.exist?(@opts[:remote_base_dir])
      end

      def validate_remote_opts
        keys = @opts.keys
        raise 'Missing remote base dir' unless keys.include?(:remote_base_dir)
        raise 'Missing remote user' unless keys.include?(:remote_user)
        raise 'Missing remote host' unless keys.include?(:remote_host)
        res = `#{generate_ssh_command("[[ -d '#{@opts[:remote_base_dir]}' ]] && echo 'ok' || echo 'missing'")}`
        raise 'Cannot connect to remote' if res.empty?
        raise 'Remote base dir invalid' unless res.strip == 'ok'
      end

      def perform_initial_rsync
        logger.info 'Running initial sync'
        IO.popen(rsync_cmd_string).each do |line|
          logger.debug line.chomp
        end
        logger.debug 'Initial sync complete'
      end

      def find_all_folders
        local_folders = process_raw_file_list(`find #{base_dir} -type d`, base_dir)

        remote_find_cmd = "find #{@opts[:remote_base_dir]} -type d"
        raw_remote_folders = `#{@opts[:remote_mode] ? generate_ssh_command(remote_find_cmd) : remote_find_cmd}`
        remote_folders = process_raw_file_list(raw_remote_folders, @opts[:remote_base_dir])

        remote_folders | local_folders
      end

      def process_raw_file_list(output, base)
        output.split("\n").tap { |a| a.shift(1) }
              .map { |path| path.sub(base, '') }
      end

      def find_rsync_ignore_folders
        ignore_matches = find_all_folders.map do |path|
          @opts[:ignore].map { |regexp| (regexp.match(path) || [])[0] }.compact.first
        end.compact.uniq
        ignore_matches.map { |path| path[1..-1] }
      end

      def generate_ssh_command(cmd)
        "ssh -q #{remote_hostname} -p #{@opts[:remote_port]} -C \"#{cmd}\""
      end

      def remote_hostname
        "#{@opts[:remote_user]}@#{@opts[:remote_host]}"
      end

      def rsync_cmd_string
        exclude_args = find_rsync_ignore_folders.map { |path| "--exclude #{path}" }.join(' ')
        remote_path = @opts[:remote_mode] ? "#{@opts[:remote_user]}@#{@opts[:remote_host]}:" : ''
        remote_path += "#{@opts[:remote_base_dir]}/"

        cmd = "rsync -azv #{exclude_args}"
        cmd += " -e \"ssh -p #{@opts[:remote_port]}\"" if @opts[:remote_mode]
        cmd + " --delete #{base_dir}/ #{remote_path}"
      end
    end
  end
end
