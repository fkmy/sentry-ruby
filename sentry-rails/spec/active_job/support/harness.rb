# frozen_string_literal: true

RSpec.shared_context "active_job backend harness" do |adapter:|
  let(:adapter) { adapter }
  let(:configure_sentry) { proc { } }

  around do |example|
    make_basic_app(&configure_sentry)
    setup_sentry_test

    ::ActiveJob::Base.queue_adapter = adapter

    boot_adapter(adapter)

    example.run
  ensure
    reset_adapter(adapter)

    teardown_sentry_test
  end

  def boot_adapter(adapter)
    case adapter
    when :solid_queue
      Sentry::Rails::Test::Application.load_queue_schema
    end
  end

  def reset_adapter(adapter)
    case adapter
    when :solid_queue
      [
        SolidQueue::ReadyExecution,
        SolidQueue::ClaimedExecution,
        SolidQueue::FailedExecution,
        SolidQueue::BlockedExecution,
        SolidQueue::ScheduledExecution,
        SolidQueue::RecurringExecution,
        SolidQueue::Process,
        SolidQueue::Job
      ].each(&:delete_all)
    end
  end

  def drain(at: nil)
    case adapter
    when :test
      if RAILS_VERSION < 6.0
        # Rails 5.2: perform_enqueued_jobs always requires a block and only runs
        # jobs enqueued *inside* the block. Manually flush already-enqueued jobs.
        jobs = queue_adapter.enqueued_jobs.dup
        queue_adapter.enqueued_jobs.clear
        jobs.each { |payload| send(:instantiate_job, payload).perform_now }
      else
        kwargs = at ? { at: at } : {}
        perform_enqueued_jobs(**kwargs)
      end
    when :solid_queue
      process = SolidQueue::Process.register(
        kind: "Worker",
        pid: ::Process.pid,
        name: "spec-#{SecureRandom.hex(4)}"
      )

      SolidQueue::ReadyExecution.claim("*", 100, process.id).each(&:perform)
    else
      raise NotImplementedError, "active_job backend harness has no drain strategy for adapter: #{adapter.inspect}"
    end
  end

  def job_fixture(name = nil, &block)
    name ||= "JobFixture_#{SecureRandom.hex(4)}"
    klass = Class.new(::ActiveJob::Base, &block)
    stub_const(name, klass)
    klass
  end

  def transactions
    sentry_events.select { |e| e.is_a?(Sentry::TransactionEvent) }
  end

  def consumer_transaction
    transactions.find { |t| t.contexts.dig(:trace, :op) == "queue.active_job" }
  end

  def within_parent_transaction(name: "parent.test", op: "test")
    txn = Sentry.start_transaction(name: name, op: op)
    Sentry.get_current_scope.set_span(txn) if txn
    yield(txn)
  ensure
    txn&.finish
  end

  # Hook used by the worker_hub_isolation shared example. The default
  # is a plain Thread.new — adapters that need extra setup (e.g. an
  # isolated database per worker thread, like :solid_queue on SQLite)
  # override this to wrap the block in their isolation scope.
  def worker_thread(&block)
    Thread.new(&block)
  end
end
