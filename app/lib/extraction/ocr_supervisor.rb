# frozen_string_literal: true

require "fileutils"
require "json"
require "uri"

module Extraction
  # Owns the local OCR sidecar process when the app is configured to use a
  # localhost PaddleOCR backend. External/remote OCR backends should be
  # supervised by their platform and pointed to with EXTRACTION_PADDLE_URL.
  class OcrSupervisor
    LOCAL_HOSTS = %w[127.0.0.1 localhost ::1].freeze

    Result = Data.define(:ok, :pid, :message) do
      def ok?
        ok
      end
    end

    class ProcessManager
      def alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def spawn_ocr(env:, command:, root_path:, log_path:)
        out = File.open(log_path, "a")
        pid = Process.spawn(
          env,
          "bash",
          command,
          chdir: root_path,
          out: out,
          err: [ :child, :out ],
          pgroup: true
        )
        Process.detach(pid)
        pid
      ensure
        out&.close
      end
    end

    class FileSystem
      def executable?(path)
        File.executable?(path)
      end

      def mkdir_p(path)
        FileUtils.mkdir_p(path)
      end

      def read_pid(path)
        Integer(File.read(path), exception: false)
      rescue Errno::ENOENT
        nil
      end

      def write_pid(path, pid)
        File.write(path, "#{pid}\n")
      end

      def with_lock(path)
        File.open(path, File::RDWR | File::CREAT, 0o644) do |file|
          file.flock(File::LOCK_EX)
          yield
        ensure
          file.flock(File::LOCK_UN)
        end
      end
    end

    def self.build
      new(
        config: Rails.application.config.x.extraction,
        process_manager: ProcessManager.new,
        file_system: FileSystem.new,
        root_path: Rails.root.to_s,
        logger: Rails.logger
      )
    end

    def initialize(config:, process_manager:, file_system:, root_path:, logger:)
      @config = config
      @process_manager = process_manager
      @file_system = file_system
      @root_path = root_path
      @logger = logger
    end

    def ensure_running
      return Result.new(false, nil, "OCR auto-start is disabled") unless @config.ocr_auto_start
      return Result.new(false, nil, "OCR backend is not local: #{@config.paddle_url}") unless local_backend?

      pid = alive_pid
      return Result.new(true, pid, "OCR sidecar already running") if pid

      @file_system.mkdir_p(File.dirname(pidfile_path))
      @file_system.mkdir_p(File.dirname(log_path))

      @file_system.with_lock(lockfile_path) do
        pid = alive_pid
        return Result.new(true, pid, "OCR sidecar already running") if pid

        start_sidecar
      end
    end

    private

    def start_sidecar
      uvicorn_path = File.join(@root_path, "ocr_service/.venv/bin/uvicorn")
      unless @file_system.executable?(uvicorn_path)
        return Result.new(false, nil, "OCR virtualenv is missing; run ocr_service/bin/setup")
      end

      pid = @process_manager.spawn_ocr(
        env: start_env,
        command: @config.ocr_start_command,
        root_path: @root_path,
        log_path: log_path
      )
      @file_system.write_pid(pidfile_path, pid)
      @logger.info(JSON.generate({
        event: "ocr_sidecar_started",
        pid: pid,
        paddle_url: @config.paddle_url,
        log_path: log_path
      }))
      Result.new(true, pid, "OCR sidecar started")
    end

    def start_env
      {
        "OCR_PORT" => backend_uri.port.to_s,
        "OCR_HOST" => backend_uri.host
      }
    end

    def alive_pid
      pid = @file_system.read_pid(pidfile_path)
      return nil if pid.nil?

      @process_manager.alive?(pid) ? pid : nil
    end

    def local_backend?
      LOCAL_HOSTS.include?(backend_uri.host)
    end

    def backend_uri
      @backend_uri ||= URI(@config.paddle_url)
    end

    def pidfile_path
      @config.ocr_service_pidfile
    end

    def lockfile_path
      "#{pidfile_path}.lock"
    end

    def log_path
      @config.ocr_service_log
    end
  end
end
