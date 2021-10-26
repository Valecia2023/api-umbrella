require "ipaddr"
require "open3"
require "singleton"
require "support/api_umbrella_test_helpers/shell"

module ApiUmbrellaTestHelpers
  class Process
    include Singleton
    include ApiUmbrellaTestHelpers::Shell

    EMBEDDED_ROOT = File.join(API_UMBRELLA_SRC_ROOT, "build/work/stage/opt/api-umbrella/embedded").freeze
    TEST_RUN_ROOT = File.join(API_UMBRELLA_SRC_ROOT, "test/tmp/run")
    TEST_RUN_API_UMBRELLA_ROOT = File.join(TEST_RUN_ROOT, "api-umbrella-root")
    TEST_ARTIFACTS_ROOT = File.join(API_UMBRELLA_SRC_ROOT, "test/tmp/artifacts")
    DEFAULT_CONFIG_PATH = File.join(API_UMBRELLA_SRC_ROOT, "config/default.yml").freeze
    CONFIG_PATH = File.join(API_UMBRELLA_SRC_ROOT, "config/test.yml").freeze
    CONFIG_COMPUTED_PATH = File.join(TEST_RUN_ROOT, "test_computed.yml").freeze
    CONFIG_OVERRIDES_PATH = File.join(TEST_RUN_ROOT, "test_overrides.yml").freeze
    CONFIG = "#{CONFIG_PATH}:#{CONFIG_COMPUTED_PATH}:#{CONFIG_OVERRIDES_PATH}".freeze
    @@incrementing_unique_ip_addr = IPAddr.new("200.0.0.1")

    def start
      Minitest.after_run do
        self.stop
      end

      start_time = Time.now.utc
      FileUtils.rm_rf(Dir.glob(File.join(TEST_ARTIFACTS_ROOT, "*"), File::FNM_DOTMATCH) - [File.join(TEST_ARTIFACTS_ROOT, "."), File.join(TEST_ARTIFACTS_ROOT, ".."), File.join(TEST_ARTIFACTS_ROOT, "reports")])
      FileUtils.mkdir_p(TEST_ARTIFACTS_ROOT)
      FileUtils.rm_rf(Dir.glob(File.join(TEST_RUN_ROOT, "*"), File::FNM_DOTMATCH) - [File.join(TEST_RUN_ROOT, "."), File.join(TEST_RUN_ROOT, "..")])
      FileUtils.mkdir_p(TEST_RUN_API_UMBRELLA_ROOT)

      original_env = ENV.to_hash
      begin
        elasticsearch_test_api_version = nil
        if ENV["ELASTICSEARCH_TEST_API_VERSION"]
          elasticsearch_test_api_version = ENV["ELASTICSEARCH_TEST_API_VERSION"].to_i
        end

        elasticsearch_test_template_version = nil
        if ENV["ELASTICSEARCH_TEST_TEMPLATE_VERSION"]
          elasticsearch_test_template_version = ENV["ELASTICSEARCH_TEST_TEMPLATE_VERSION"].to_i
        end

        elasticsearch_test_index_partition = nil
        if ENV["ELASTICSEARCH_TEST_INDEX_PARTITION"]
          elasticsearch_test_index_partition = ENV["ELASTICSEARCH_TEST_INDEX_PARTITION"]
        end

        # Read the initial test config file.
        $config = YAML.load_file(DEFAULT_CONFIG_PATH)
        $config.deep_merge!(YAML.load_file(CONFIG_PATH))

        # Create an config file for computed overrides.
        computed = {
          "root_dir" => TEST_RUN_API_UMBRELLA_ROOT,
          "geoip" => {
            "maxmind_license_key" => ENV["MAXMIND_LICENSE_KEY"],
          },
        }
        if(::Process.euid == 0)
          # If tests are running as root (Docker environment), then add the
          # user to run things as.
          computed["user"] = "api-umbrella"
          computed["group"] = "api-umbrella"
        end
        if elasticsearch_test_api_version
          computed.deep_merge!({
            "elasticsearch" => {
              "api_version" => elasticsearch_test_api_version,
            },
          })
        end
        if elasticsearch_test_template_version
          computed.deep_merge!({
            "elasticsearch" => {
              "template_version" => elasticsearch_test_template_version,
            },
          })
        end
        if elasticsearch_test_index_partition
          computed.deep_merge!({
            "elasticsearch" => {
              "index_partition" => elasticsearch_test_index_partition,
            },
          })
        end
        if elasticsearch_test_api_version || elasticsearch_test_template_version || elasticsearch_test_index_partition
          dir_suffix = [
            elasticsearch_test_api_version,
            elasticsearch_test_template_version,
            elasticsearch_test_index_partition,
          ].join("-")
          computed.deep_merge!({
            "elasticsearch" => {
              "embedded_server_config" => {
                "path" => {
                  "data" => File.join(TEST_RUN_API_UMBRELLA_ROOT, "var/db/elasticsearch-#{dir_suffix}"),
                  "logs" => File.join(TEST_ARTIFACTS_ROOT, "log/elasticsearch-#{dir_suffix}"),
                },
              },
            },
          })
        end
        File.write(CONFIG_COMPUTED_PATH, YAML.dump(computed))
        $config.deep_merge!(YAML.load_file(CONFIG_COMPUTED_PATH))

        # Create an empty config file for test-specific overrides.
        File.write(CONFIG_OVERRIDES_PATH, YAML.dump({ "version" => 0 }))

        # Trigger a build to ensure the tests get run with the latest
        # environment. This takes care of tasks in the sub-components, like
        # bundling new dependencies, or recompiling the javascript files.
        build = ChildProcess.build("make")
        build.io.inherit!
        build.cwd = API_UMBRELLA_SRC_ROOT
        build.start
        build.wait
        if(build.crashed?)
          exit build.exit_code
        end

        ActiveRecord::Base.establish_connection({
          :adapter => "postgresql",
          :host => $config["postgresql"]["host"],
          :port => $config["postgresql"]["port"],
          :database => "postgres",
          :username => "postgres",
          :password => "dev_password",
        })
        ActiveRecord::Base.connection.execute("DROP DATABASE IF EXISTS #{ActiveRecord::Base.connection.quote_column_name($config["postgresql"]["database"])}")

        db_setup_output, db_setup_status = Open3.capture2e({
          "API_UMBRELLA_EMBEDDED_ROOT" => EMBEDDED_ROOT,
          "API_UMBRELLA_CONFIG" => CONFIG,
          "DB_USERNAME" => "postgres",
          "DB_PASSWORD" => "dev_password",
        }, File.join(API_UMBRELLA_SRC_ROOT, "bin/api-umbrella"), "db-setup")
        unless db_setup_status.success?
          warn "Error: Database setup failed:\n\n#{db_setup_output}"
          exit db_setup_status.exitstatus
        end

        # Spin up API Umbrella and the embedded databases as a background
        # process.
        $api_umbrella_process = ChildProcess.build(File.join(API_UMBRELLA_SRC_ROOT, "bin/api-umbrella"), "run")
        $api_umbrella_process.io.inherit!
        $api_umbrella_process.environment["API_UMBRELLA_EMBEDDED_ROOT"] = EMBEDDED_ROOT
        $api_umbrella_process.environment["API_UMBRELLA_CONFIG"] = CONFIG
        $api_umbrella_process.leader = true
        $api_umbrella_process.start

        # Run the health command to wait for API Umbrella to fully startup.
        health = ChildProcess.build(File.join(API_UMBRELLA_SRC_ROOT, "bin/api-umbrella"), "health", "--wait-for-status", "green", "--wait-timeout", "50")
        health.io.inherit!
        health.environment["API_UMBRELLA_EMBEDDED_ROOT"] = EMBEDDED_ROOT
        health.environment["API_UMBRELLA_CONFIG"] = CONFIG
        health.start

        progress = Thread.new do
          print "Waiting for api-umbrella to start..."
          loop do
            if($api_umbrella_process.crashed?)
              health.stop
              break
            end

            print "."
            sleep 2
          end
        end

        health.wait
        progress.exit

        end_time = Time.now.utc
        puts format("(%<time>.2fs)", :time => end_time - start_time)

        # If anything exited unsuccessfully, abort tests.
        if(health.crashed? || $api_umbrella_process.crashed?)
          raise "Did not start api-umbrella process for integration tests"
        end

        # Once API Umbrella is started, read the config from the runtime file.
        # This allows the tests to access the full config (accounting for
        # merging config from multiple sources and any computed config
        # settings).
        runtime_config_path = File.join($config["root_dir"], "var/run/runtime_config.yml")
        unless(File.exist?(runtime_config_path))
          raise "runtime_config.yml file not found after starting: #{runtime_config_path.inspect}"
        end

        $config = YAML.load_file(runtime_config_path)
      ensure
        # Restore the original environment before we wiped the bundler
        # variables.
        ENV.replace(original_env)
      end

    # If anything fails during API Umbrella's startup, make sure we attempt to
    # stop the API Umbrella process, so we don't leave processes hanging
    # around.
    #
    # This is also a case where we do want to rescue the low-level Exception
    # class to ensure we have a chance to properly stop the child process on
    # things like SIGINTs.
    rescue Exception => e # rubocop:disable Lint/RescueException
      puts "Error occurred while starting api-umbrella, stopping..."
      puts e.message
      puts e.backtrace.join("\n")

      self.stop
      raise e
    end

    def stop
      if($api_umbrella_process && $api_umbrella_process.alive?)
        puts "Stopping api-umbrella..."

        begin
          stop = ChildProcess.build(File.join(API_UMBRELLA_SRC_ROOT, "bin/api-umbrella"), "stop")
          stop.io.inherit!
          stop.environment["API_UMBRELLA_EMBEDDED_ROOT"] = EMBEDDED_ROOT
          stop.environment["API_UMBRELLA_CONFIG"] = CONFIG
          stop.start
          stop.wait

          if(stop.exit_code != 0)
            raise "api-umbrella failed to stop"
          end
        ensure
          $api_umbrella_process.stop
        end
      end
    end

    def reload
      # Read the currently active config (to detect any changes in
      # $config["nginx"]["workers"]).
      runtime_config_path = File.join($config["root_dir"], "var/run/runtime_config.yml")
      $config = YAML.load_file(runtime_config_path)

      # Get the list of original nginx worker process PIDs on startup.
      nginx_parent_pid = perp_pid("nginx")
      original_nginx_child_pids = nginx_child_pids(nginx_parent_pid, $config["nginx"]["workers"])
      nginx_web_app_parent_pid = perp_pid("nginx-web-app")
      original_nginx_web_app_child_pids = nginx_child_pids(nginx_web_app_parent_pid, $config["web"]["workers"])

      # Send the reload command.
      reload = ChildProcess.build(*[File.join(API_UMBRELLA_SRC_ROOT, "bin/api-umbrella"), "reload"].flatten.compact)
      reload.io.inherit!
      reload.environment["API_UMBRELLA_EMBEDDED_ROOT"] = EMBEDDED_ROOT
      reload.environment["API_UMBRELLA_CONFIG"] = CONFIG
      reload.start
      reload.wait

      # Re-read the currently active config after reloading (to detect any
      # changes in $config["nginx"]["workers"]).
      $config = YAML.load_file(runtime_config_path)

      # After sending the reload signal, wait until only the new set of worker
      # processes is running. This prevents race conditions from occurring
      # while testing reloads where some of the workers may still be reflecting
      # the old configuration, while new workers have the new configuration. By
      # waiting for all the workers to be new, that ensures a consistent point
      # to test from.
      nginx_wait_for_new_child_pids(nginx_parent_pid, $config["nginx"]["workers"], original_nginx_child_pids)
      nginx_wait_for_new_child_pids(nginx_web_app_parent_pid, $config["web"]["workers"], original_nginx_web_app_child_pids)
    end

    def processes
      env = {
        "API_UMBRELLA_EMBEDDED_ROOT" => EMBEDDED_ROOT,
        "API_UMBRELLA_CONFIG" => CONFIG,
      }
      output, status = Open3.capture2e(env, File.join(API_UMBRELLA_SRC_ROOT, "bin/api-umbrella"), "processes")

      if status.exitstatus != 0
        raise "api-umbrella processes failed: #{output}"
      end

      output
    end

    def perp_signal(service_name, signal_name)
      output, status = run_shell("perpctl", "-b", File.join($config["root_dir"], "etc/perp"), signal_name, service_name)
      if(status != 0)
        raise "perpctl failed (status: #{status}): #{output}"
      end
    end

    def perp_pid(service_name)
      pid = nil
      begin
        # If api-umbrella is actively being reloaded, then the "perphup" signal
        # sent to perp may temporarily result in perpstat not thinking services
        # are activated until the reload has finished (so no pids will be
        # returned). So retry fetching the pids for a while to account for this
        # timing edge-case while reloads are being tested.
        Timeout.timeout(5) do
          loop do
            output, _status = run_shell("perpstat", "-b", File.join($config["root_dir"], "etc/perp"), service_name)
            matches = output.match(/^\s*main: up .*\(pid (\d+)\)\s*$/)
            if matches
              pid = matches[1]
              break
            end
          end
        end
      rescue Timeout::Error
        # Ignore and return nil pid.
      end

      pid
    end

    def perp_restart(service_name, signal_name = "term")
      original_pid = perp_pid(service_name)
      if !original_pid
        raise "failed to find pid for #{service_name}"
      end

      perp_signal(service_name, signal_name)

      # Sleep to ensure that the kill signal is received and it's had a chance
      # to die and restart the new process (so we don't move on before the
      # process has actually been killed).
      restarted_pid = nil
      begin
        Timeout.timeout(10) do
          loop do
            restarted_pid = perp_pid(service_name)
            if(restarted_pid && restarted_pid != original_pid)
              break
            end

            sleep 0.1
          end
        end
      rescue Timeout::Error
        raise Timeout::Error, "Failed to restart #{service_name}. Waiting for PID to change. Original PID: #{original_pid}. Last PID: #{restarted_pid}"
      end
    end

    def restart_trafficserver
      perp_restart("trafficserver")
      restarted_pid = perp_pid("trafficserver")

      # After killing and restarting trafficserver, wait for it to come back
      # online (since this full restart isn't a normal occurrence and will
      # incur downtime).
      #
      # Note that we're currently doing this to reload DNS changes within
      # Traffic Server. We could also call `traffic_ctl server restart` which
      # just restarts the traffic_server process (and not the manager), which
      # appears to work without any downtime. However, while DNS changes are
      # picked up after that type of restart, it's hard to predict when those
      # changes are fully live within trafficserver, so that's why we[re opting
      # for this full restart to handle DNS changes in the test suite (in real
      # live, DNS server changes shouldn't be likely, though, so this is mainly
      # a test environment issue).
      response = nil
      begin
        Timeout.timeout(40) do
          loop do
            url = "http://127.0.0.1:9080/api-umbrella/v1/health?#{rand}"
            response = Typhoeus.get(url)
            if(response.code == 200)
              break
            end

            sleep 0.1
          end
        end
      rescue Timeout::Error
        raise Timeout::Error, "Trafficserver restart failed. Status: #{response&.code} Body: #{response&.body}"
      end

      # Sanity check to ensure Trafficserver was only restarted once, and isn't
      # flapping on and off.
      current_pid = perp_pid("trafficserver")
      if(restarted_pid != current_pid)
        raise "Trafficserver was restarted multiple times, this is not expected (post-restart pid: #{restarted_pid}, current pid: #{current_pid})"
      end
    end

    def wait_for_config_version(field, version, config = {})
      state = nil
      health = nil
      begin
        Timeout.timeout(10) do
          loop do
            state = self.fetch("http://127.0.0.1:9080/api-umbrella/v1/state?#{rand}", config)
            if(state[field].to_s == version.to_s && state.dig("web_app", field).to_s == version.to_s)
              health = self.fetch("http://127.0.0.1:9080/api-umbrella/v1/health?#{rand}", config)
              if(health["status"] == "green")
                break
              end
            end

            sleep 0.1
          end
        end
      rescue Timeout::Error
        raise Timeout::Error, "API Umbrella configuration changes were not detected. Waiting for version #{field}=#{version} and status=green. Last seen: #{state.inspect} #{health.inspect}"
      end
    end

    def fetch(url, config)
      http_opts = {}

      # If we're performing global rate limit tests, use a different IP address
      # for each internal API request when trying to determine if the config is
      # published. This prevents us from accidentally hitting these global rate
      # limits in our rapid polling requests to determine if things are ready.
      if(config && config["router"] && config["router"]["global_rate_limits"])
        @@incrementing_unique_ip_addr = @@incrementing_unique_ip_addr.succ
        http_opts.deep_merge!({
          :headers => {
            "X-Forwarded-For" => @@incrementing_unique_ip_addr.to_s,
          },
        })
      end

      response = Typhoeus.get(url, http_opts)
      begin
        data = MultiJson.load(response.body)
      rescue MultiJson::ParseError => e
        raise MultiJson::ParseError, "#{e.message}: #{url} failure (#{response.code}): #{response.body}"
      end

      data
    end

    def all_processes
      pid = File.read(File.join($config["run_dir"], "perpboot.pid")).strip
      output, status = run_shell("pstree", "-p", pid)
      if(status != 0)
        raise "pstree failed (status: #{status}): #{output}"
      end

      pids = output.scan(/\((\d+)\)/).flatten.sort.uniq
      if(pids.empty?)
        raise "pstree failed to detect PIDs: #{output}"
      end

      output, status = run_shell("ps", "-o", "uname=", "-p", pids.join(","))
      if(status != 0)
        raise "ps failed (status: #{status}): #{output}"
      end

      owners = output.split("\n").sort.uniq
      if(owners.empty?)
        raise "pstree failed to detect owners: #{output}"
      end

      {
        :pids => pids,
        :owners => owners,
      }
    end

    def nginx_child_pids(parent_pid, expected_num_workers)
      parent_pid = Integer(parent_pid)
      expected_num_workers = Integer(expected_num_workers)

      pids = []
      output = nil
      begin
        Timeout.timeout(70) do
          loop do
            output, status = run_shell("pgrep", "-P", parent_pid)
            if status != 0
              raise "Error fetching nginx child PIDs: #{output}"
            end

            pids = output.strip.split("\n")
            break if(pids.length == expected_num_workers)

            sleep 0.1
          end
        end
      rescue Timeout::Error
        raise "Did not find expected number of nginx child processes (#{expected_num_workers}). Last PIDs seen: #{pids.inspect} Last output: #{output.inspect}"
      end

      pids
    end

    def nginx_wait_for_new_child_pids(parent_pid, expected_num_workers, original_child_pids)
      new_child_pids = nil
      begin
        Timeout.timeout(70) do
          loop do
            new_child_pids = nginx_child_pids(parent_pid, expected_num_workers)
            pid_intersection = new_child_pids & original_child_pids
            break if(pid_intersection.empty?)

            sleep 0.1
          end
        end
      rescue Timeout::Error
        raise "nginx child processes did not change during reload. original_child_pids: #{original_child_pids.inspect} new_child_pids: #{new_child_pids.inspect}"
      end
    end
  end
end
