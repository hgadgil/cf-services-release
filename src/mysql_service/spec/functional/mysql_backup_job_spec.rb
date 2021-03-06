require 'spec_helper'
require 'mysql_service/node'
require 'mysql_service/util'
require 'mysql_service/job'

module VCAP::Services::Mysql::Backup
  describe "backup jobs", components: [:nats], hook: :all do
    include VCAP::Services::Base::AsyncJob
    PASSWORD = 'oldpassword'
    before :all do
      `which redis-server`
      pending "Redis not installed" unless $?.success?
      start_redis

      @config = Yajl::Parser.parse(ENV["WORKER_CONFIG"])
      VCAP::Services::Base::AsyncJob::Config.redis_config = @config["resque"]
      VCAP::Services::Base::AsyncJob::Config.logger = getLogger

      Resque.inline = true

      Fog.mock!
      @connection = Fog::Storage.new({
        :aws_access_key_id      => 'fake_access_key_id',
        :aws_secret_access_key  => 'fake_secret_access_key',
        :provider               => 'AWS'
      })
      StorageClient.instance_variable_set(:@storage_connection, @connection)

      @test_dbs = []
      @opts = getNodeTestConfig
      @default_plan = @opts[:plan]
      @default_version = @opts[:default_version]
      @use_warden = @opts[:use_warden]
      creds = {
          "service_id" => UUIDTools::UUID.random_create.to_s,
          "name"       => 'pooltest',
          "user"       => 'user',
          "password"   => PASSWORD,
      }
      EM.run do
        @node = VCAP::Services::Mysql::Node.new(@opts)
        EM.add_timer(1) do
          @db = @node.provision(@default_plan, creds, @default_version)

          @test_dbs << @db

          conn = connect_to_mysql(@db, creds['password'])
          conn.query("CREATE TABLE test(id INT)")
          conn.query("INSERT INTO test VALUE(10)")
          conn.query("INSERT INTO test VALUE(20)")

          EM.stop
        end
      end if @use_warden
    end

    after :each do
      if @pid
        Process.kill 9, @pid
        Process.wait @pid
      end
    end

    after :all do
      EM.run do
        @test_dbs.each do |db|
          begin
            service_id = db["service_id"]
            @node.unprovision(service_id, [])
            @node.instance_variable_get(:@logger).info("Clean up temp database: #{service_id}")
          rescue => e
            @node.instance_variable_get(:@logger).info("Error during cleanup #{e}")
          end
        end if @test_dbs

        EM.stop
      end if @use_warden
      stop_redis
    end

    describe "create, restore and delete backup jobs" do

      def subscribe_backup_or_delete_channel(service_name, channel, mbus)
        @client ||= NATS.connect(:uri => mbus)
        @client.subscribe(channel) do |msg, reply|
          res = VCAP::Services::Internal::BackupJobResponse.decode(msg)
          res.success.should eq true
          if channel =~ /create/
            res.properties.should include("size", "date", "status")
          else
            res.properties.should include("service_id", "backup_id")
          end
          sr = VCAP::Services::Internal::SimpleResponse.new
          sr.success = true
          @client.publish(reply, sr.encode)
        end
      end

      def create_and_check(service_name, service_id, backup_id, node_id, metadata)
        job_id = CreateBackupJob.create(:service_id => service_id,
                                        :backup_id  => backup_id,
                                        :node_id    => @opts[:node_id],
                                        :metadata   => metadata)

        job_status = get_job(job_id)
        backup_id.should eq job_status[:result]["backup_id"]
      end

      def subscribe_restore_channel(service_name, service_id_for_restore, mbus)
        @client ||= NATS.connect(:uri => mbus)
        channel = "#{service_name}.restore_backup.#{service_id_for_restore}"

        subscription = @client.subscribe(channel) do |msg, reply|
          @client.unsubscribe(subscription)
          res = VCAP::Services::Internal::SimpleResponse.decode(msg)
          res.success.should eq true
          sr = VCAP::Services::Internal::SimpleResponse.new
          sr.success = true
          @client.publish(reply, sr.encode)
        end
      end

      def restore_and_check(service_id_for_restore, original_service_id, backup_id, trigger_by)
        RestoreBackupJob.create(:service_id          => service_id_for_restore,
                                :original_service_id => original_service_id,
                                :node_id             => @opts[:node_id],
                                :backup_id           => backup_id,
                                :metadata            => {:trigger_by      => trigger_by,
                                                         :properties      => {
                                                           :service_version => "5.6"}
                                                        }
                               )

        # only supports warden
        data_dir = @config["mysqld"]["5.6"]["datadir"]
        file_to_check = File.join(data_dir, service_id_for_restore, "data", "ibdata1")
        File.exists?(file_to_check).should == true
      end

      def check_data_in_new_db(service_id_for_restore, old_password)
        EM.run do
          creds = {
            "service_id" => service_id_for_restore,
            "name"       => @db["name"],
            "user"       => @db["user"],
          }
          db = @node.provision(@default_plan, creds, @default_version, {"is_restoring" => true})
          @test_dbs << db
          conn = connect_to_mysql(db, old_password)
          conn.query("select * from test").each(:symbolize_keys => true) do |row|
            [10, 20].should include(row[:id])
          end

          EM.stop
        end
      end

      def delete_and_check(service_name, service_id, backup_id)
        job_id = DeleteBackupJob.create(:service_id => service_id,
                                        :backup_id  => backup_id,
                                        :node_id    => @opts[:node_id],
                                        :metadata   => {})

        job_status = get_job(job_id)
        job_status[:result]["result"].should eq "ok"

        StorageClient.get_file(service_name, service_id, backup_id).should be_nil
      end

      it "should be able to create full & incremental backups and restore them" do
        service_id = @db["service_id"]
        backup_id = nil
        service_name = "MyaaS"
        ["full", "incremental"].each do |type|
          backup_id = UUIDTools::UUID.random_create.to_s
          create_and_check(service_name, service_id, backup_id, @opts[:node_id], {:type => type})

          instance_backup_info = DBClient.get_instance_backup_info(service_id)
          instance_backup_info.should_not be_nil
          instance_backup_info.values_at(:last_lsn, :last_backup).should_not include(nil)

          single_backup_info = DBClient.get_single_backup_info(service_id, backup_id)
          single_backup_info.should_not be_nil
          single_backup_info.values_at(:backup_id, :type, :date, :manifest).should_not include(nil)

          StorageClient.get_file("MyaaS", service_id, backup_id).should_not be_nil
        end

        service_id_for_restore = "restored_db"

        @pid = fork do
          EM.run do
            subscribe_restore_channel(service_name, service_id_for_restore, @config["mbus"])
          end
        end

        VCAP::Services::Base::AsyncJob::Config.logger.should_not_receive(:error)
        restore_and_check(service_id_for_restore, service_id, backup_id, "auto")

        check_data_in_new_db(service_id_for_restore, PASSWORD)
      end

      it "should be able to handle user triggered backup & restore" do
        service_id = @db["service_id"]
        service_id_for_restore = "user_restored_db"
        service_name = "MyaaS"
        backup_id = UUIDTools::UUID.random_create.to_s

        @pid = fork do
          EM.run do
            subscribe_backup_or_delete_channel(service_name,
                                               "#{service_name}.create_backup",
                                               @config["mbus"])

            subscribe_restore_channel(service_name, service_id_for_restore, @config["mbus"])
          end
        end

        VCAP::Services::Base::AsyncJob::Config.logger.should_not_receive(:error)

        metadata = {:type => "full", :trigger_by => "user", :properties => {}}
        create_and_check(service_name, service_id, backup_id, @opts[:node_id], metadata)
        single_backup_info = DBClient.get_single_backup_info(service_id, backup_id)
        single_backup_info.should be_nil
        StorageClient.get_file(service_name, service_id, backup_id).should_not be_nil

        restore_and_check(service_id_for_restore, service_id, backup_id, "user")

        check_data_in_new_db(service_id_for_restore, PASSWORD)
      end

      it "should be able to delete user triggerd backup" do
        service_id = @db["service_id"]
        backup_id = UUIDTools::UUID.random_create.to_s
        service_name = "MyaaS"
        @pid = fork do
          EM.run do
            subscribe_backup_or_delete_channel(service_name,
                                               "#{service_name}.create_backup",
                                               @config["mbus"])

            subscribe_backup_or_delete_channel(service_name,
                                               "#{service_name}.delete_backup",
                                               @config["mbus"])
          end
        end

        metadata = {:type => "full", :trigger_by => "user", :properties => {}}
        create_and_check(service_name, service_id, backup_id, @opts[:node_id], metadata)

        VCAP::Services::Base::AsyncJob::Config.logger.should_not_receive(:error)
        delete_and_check(service_name, service_id, backup_id)
      end
    end
  end
end
