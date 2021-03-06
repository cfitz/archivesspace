require 'parallel_tests'
require 'test_utils'

require 'sinatra/base'
require_relative '../indexer/app/lib/realtime_indexer'
require_relative '../indexer/app/lib/periodic_indexer'

require_relative 'spec/parallel_formatter_html'
require_relative 'spec/parallel_formatter_out'

require_relative 'spec/spec_helper'


namespace :integration do

  task :staff do
    standalone = true
    indexer_thread = nil

    pattern = ENV['pattern'] || "_spec.rb"
    cores = ENV['cores'] || "2"
    dir = ENV['dir'] || 'spec'

    parallel_spec_opts = ["--type", "rspec", "--suffix", pattern]

    if ENV['only_group']
      parallel_spec_opts << "--only-group" << ENV['only_group']
    end

    if ENV["ASPACE_BACKEND_URL"] and ENV["ASPACE_FRONTEND_URL"]
      puts "Backend and Staff applications already running"
      ENV['ASPACE_SOLR_URL'] = AppConfig[:solr_url]
      standalone = false
    else
      Rake::Task["servers:start"].invoke
    end

    indexer_port = TestUtils::free_port_from(2727)
    indexer_thread = Thread.new do
      Rake::Task["servers:indexer:start"].invoke(indexer_port)
    end

    ENV['ASPACE_INDEXER_URL'] = "http://localhost:#{indexer_port}"

    begin
      ParallelTests::CLI.new.run(parallel_spec_opts + ["--test-options", "--fail-fast --format 'ParallelFormatterOut' --format 'ParallelFormatterHTML'", "-n", cores, dir])

    ensure
      if standalone
        Rake::Task["servers:stop"].invoke
      end
    end

  end
end


namespace :servers do
  task :start do
    if ENV["ASPACE_BACKEND_URL"] and ENV["ASPACE_FRONTEND_URL"]
      puts "Running tests against a server already started"
    # Some versions of Java do not seem to respect the ensure block if STOP is
    # given in ant, which means sometimes pid files get left behind by
    # accident. 
    elsif File.exist? '/tmp/backend_test_server.pid'
      puts <<MSG
    WARNING: Backend Process PID file already exists (/tmp/backend_test_server.pid)
    If this is a mistake, please remove this file and restart the tests.
MSG
    elsif File.exist? '/tmp/frontend_test_server.pid'
      puts <<MSG
    Frontend Process PID file already exists (/tmp/frontend_test_server.pd)
    If this is a mistake, please remove this file and restart the tests.
MSG
    else
      backend_port = TestUtils::free_port_from(3636)
      frontend_port = TestUtils::free_port_from(4545)
      solr_port = TestUtils::free_port_from(2989)

      backend_url = "http://localhost:#{backend_port}"
      frontend_url = "http://localhost:#{frontend_port}"
      solr_url = "http://localhost:#{solr_port}"

      backend_pid = TestUtils::start_backend(backend_port,
                     {
                      :frontend_url => frontend_url,
                      :solr_port => solr_port,
                      :session_expire_after_seconds => 30000,
                      :realtime_index_backlog_ms => 600000
                      })


      frontend_pid = TestUtils::start_frontend(frontend_port, backend_url)

      backend_pid_file = '/tmp/backend_test_server.pid'
      frontend_pid_file = '/tmp/frontend_test_server.pid'

      File.open(backend_pid_file, 'w'){|f| f.puts backend_pid}
      File.open(frontend_pid_file, 'w'){|f| f.puts frontend_pid}

      ENV["ASPACE_BACKEND_URL"] = backend_url
      ENV["ASPACE_FRONTEND_URL"] = frontend_url
      ENV["ASPACE_SOLR_URL"] = solr_url

    end
    puts <<MSG
    USING BACKEND URL : #{ENV["ASPACE_BACKEND_URL"]}
    USING FRONTEND URL : #{ENV["ASPACE_FRONTEND_URL"]}
    USING SOLR URL : #{ENV["ASPACE_SOLR_URL"]}
MSG
  end

  namespace :indexer do

    task :start, [:port]  do |t, args|

      indexer_url = "http://localhost:#{args[:port]}"
      AppConfig[:solr_url] = ENV['ASPACE_SOLR_URL']
      AppConfig[:backend_url] = ENV['ASPACE_BACKEND_URL']

      if AppConfig[:solr_url].nil? || AppConfig[:backend_url].nil?
        puts <<MSG
    WARNING: The :solr_url or backend_url in your AppConfig is not set.
    Your indexer may not run correctly.
MSG
      end

      AppConfig[:indexer_records_per_thread] = 25
      AppConfig[:indexer_thread_count] = 1
      AppConfig[:indexer_solr_timeout_seconds] = 300

      ENV["ASPACE_INDEXER_URL"] = indexer_url

      $indexer = RealtimeIndexer.new(ENV['ASPACE_BACKEND_URL'], nil)
      $last_sequence = 0
      $period = PeriodicIndexer.new(ENV['ASPACE_BACKEND_URL'], nil, 'Selenium Periodic Indexer', false)

      indexer = Sinatra.new {
        set :port, args[:port]
        disable :traps

        def run_index_round
          $indexer.reset_session
          $last_sequence = $indexer.run_index_round($last_sequence)
          $last_sequence
        end

        def run_periodic_index
          $period.reset_session
          $period.run_index_round
        end

        def run_all_indexers
          run_index_round
          run_periodic_index
        end

        get '/' do
          "test indexer server"
        end

        post '/run_index_round' do
          run_index_round
          200
        end

        post '/run_periodic_index' do
          run_periodic_index
          200
        end

        post '/run_all_indexers' do
          run_index_round
          run_periodic_index
          200
        end
      }

      indexer.run!
    end
  end

  task :stop do
    if File.exist? '/tmp/backend_test_server.pid'
      pid = IO.read('/tmp/backend_test_server.pid').strip.to_i
      puts "kill #{pid}"
      TestUtils.kill(pid)
      File.delete '/tmp/backend_test_server.pid'
    end

    if File.exist? '/tmp/frontend_test_server.pid'
      pid = IO.read('/tmp/frontend_test_server.pid').strip.to_i
      puts "kill #{pid}"
      TestUtils.kill(pid)
      File.delete '/tmp/frontend_test_server.pid'
    end

  end
end
