# frozen_string_literal: true

require "test_helper"

class OcrSupervisorTest < ActiveSupport::TestCase
  Config = Data.define(
    :ocr_auto_start,
    :paddle_url,
    :ocr_service_pidfile,
    :ocr_service_log,
    :ocr_start_command
  )

  class FakeProcessManager
    attr_reader :spawns

    def initialize(alive_pids:, new_pid:)
      @alive_pids = alive_pids
      @new_pid = new_pid
      @spawns = []
    end

    def alive?(pid)
      @alive_pids.include?(pid)
    end

    def spawn_ocr(env:, command:, root_path:, log_path:)
      @spawns << { env: env, command: command, root_path: root_path, log_path: log_path }
      @new_pid
    end
  end

  class FakeFileSystem
    attr_reader :made_dirs, :written_pids, :lock_paths

    def initialize(pid:, executable:)
      @pid = pid
      @executable = executable
      @made_dirs = []
      @written_pids = []
      @lock_paths = []
    end

    def executable?(_path)
      @executable
    end

    def mkdir_p(path)
      @made_dirs << path
    end

    def read_pid(_path)
      @pid
    end

    def write_pid(path, pid)
      @written_pids << [ path, pid ]
      @pid = pid
    end

    def with_lock(path)
      @lock_paths << path
      yield
    end
  end

  test "does nothing when a recorded sidecar pid is alive" do
    process_manager = FakeProcessManager.new(alive_pids: [ 4321 ], new_pid: 9999)
    file_system = FakeFileSystem.new(pid: 4321, executable: true)

    result = supervisor(process_manager: process_manager, file_system: file_system).ensure_running

    assert_predicate result, :ok?
    assert_equal 4321, result.pid
    assert_empty process_manager.spawns
  end

  test "starts the local sidecar when no alive pid is recorded" do
    process_manager = FakeProcessManager.new(alive_pids: [], new_pid: 9999)
    file_system = FakeFileSystem.new(pid: nil, executable: true)

    result = supervisor(process_manager: process_manager, file_system: file_system).ensure_running

    assert_predicate result, :ok?
    assert_equal 9999, result.pid
    assert_equal [ [ "/app/tmp/pids/ocr_service.pid", 9999 ] ], file_system.written_pids
    assert_equal [ "/app/tmp/pids/ocr_service.pid.lock" ], file_system.lock_paths
    assert_equal({
      env: { "OCR_PORT" => "8765", "OCR_HOST" => "127.0.0.1" },
      command: "/app/ocr_service/bin/serve",
      root_path: "/app",
      log_path: "/app/log/ocr_service.log"
    }, process_manager.spawns.first)
  end

  test "refuses to start without the OCR virtualenv" do
    process_manager = FakeProcessManager.new(alive_pids: [], new_pid: 9999)
    file_system = FakeFileSystem.new(pid: nil, executable: false)

    result = supervisor(process_manager: process_manager, file_system: file_system).ensure_running

    assert_not result.ok?
    assert_match(/virtualenv is missing/, result.message)
    assert_empty process_manager.spawns
  end

  test "does not start a remote OCR backend" do
    process_manager = FakeProcessManager.new(alive_pids: [], new_pid: 9999)
    file_system = FakeFileSystem.new(pid: nil, executable: true)
    config = config(paddle_url: "https://ocr.internal.example")

    result = supervisor(process_manager: process_manager, file_system: file_system, config: config).ensure_running

    assert_not result.ok?
    assert_match(/not local/, result.message)
    assert_empty process_manager.spawns
  end

  private

  def supervisor(process_manager:, file_system:, config: config(paddle_url: "http://127.0.0.1:8765"))
    Extraction::OcrSupervisor.new(
      config: config,
      process_manager: process_manager,
      file_system: file_system,
      root_path: "/app",
      logger: ActiveSupport::Logger.new(StringIO.new)
    )
  end

  def config(paddle_url:)
    Config.new(
      ocr_auto_start: true,
      paddle_url: paddle_url,
      ocr_service_pidfile: "/app/tmp/pids/ocr_service.pid",
      ocr_service_log: "/app/log/ocr_service.log",
      ocr_start_command: "/app/ocr_service/bin/serve"
    )
  end
end
