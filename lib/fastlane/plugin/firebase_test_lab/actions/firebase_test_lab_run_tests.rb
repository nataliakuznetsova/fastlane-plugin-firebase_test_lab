require_relative '../helper/ftl_service'
require_relative '../helper/ftl_message'
require_relative '../helper/storage'
require_relative '../helper/credential'
require_relative '../helper/ios_validator'
require_relative '../options'
require_relative '../commands'

require 'json'
require 'securerandom'
require 'tty-spinner'

module Fastlane
  module Actions
    class FirebaseTestLabRunTestsAction < Action
      DEFAULT_APP_BUNDLE_NAME = "bundle"
      PULL_RESULT_INTERVAL = 15

      RUNNING_STATES = %w(VALIDATING PENDING RUNNING)

      private_constant :DEFAULT_APP_BUNDLE_NAME
      private_constant :PULL_RESULT_INTERVAL
      private_constant :RUNNING_STATES

      def self.run(params)
        gcp_project = params[:gcp_project]
        gcp_requests_timeout = params[:gcp_requests_timeout]
        oauth_key_file_path = params[:oauth_key_file_path]
        gcp_credential = Fastlane::FirebaseTestLab::Credential.new(key_file_path: oauth_key_file_path)

        ftl_service = Fastlane::FirebaseTestLab::FirebaseTestLabService.new(gcp_credential)

        # The default Google Cloud Storage path we store app bundle and test results
        gcs_workfolder = generate_directory_name

        # Firebase Test Lab requires an app bundle be already on Google Cloud Storage before starting the job
        if params[:test_ios] && params[:ios_app_path].to_s.start_with?("gs://")
          # gs:// is a path on Google Cloud Storage, we do not need to re-upload the app to a different bucket
          app_gcs_link = params[:ios_app_path]
        else

          if params[:skip_validation]
            UI.message("Skipping validation of app.")
          else
            if params[:test_ios]
              FirebaseTestLab::IosValidator.validate_ios_app(params[:ios_app_path])
            end  
          end

          # When given a local path, we upload the app bundle to Google Cloud Storage
          upload_spinner = TTY::Spinner.new("[:spinner] Uploading the app(s) to GCS...", format: :dots)
          upload_spinner.auto_spin
          upload_bucket_name = ftl_service.get_default_bucket(gcp_project)
          timeout = gcp_requests_timeout ? gcp_requests_timeout.to_i : nil
          if params[:test_ios]
            app_gcs_link = upload_file(params[:ios_app_path],
                                       upload_bucket_name,
                                       "#{gcs_workfolder}/#{DEFAULT_APP_BUNDLE_NAME}",
                                       gcp_project,
                                       gcp_credential,
                                       timeout)
          else
            app_gcs_link = upload_file(params[:android_app_apk],
                                       upload_bucket_name,
                                       "#{gcs_workfolder}/app-debug.apk",
                                       gcp_project,
                                       gcp_credential,
                                       timeout)
            test_app_gcs_link = upload_file(params[:android_test_apk],
                                       upload_bucket_name,
                                       "#{gcs_workfolder}/app-debug-androidTest.apk",
                                       gcp_project,
                                       gcp_credential,
                                       timeout)
          end  
          upload_spinner.success("Done")
        end

        UI.message("Submitting job(s) to Firebase Test Lab")
        
        result_storage = (params[:result_storage] ||
          "gs://#{ftl_service.get_default_bucket(gcp_project)}/#{gcs_workfolder}")
        UI.message("Test Results bucket: #{result_storage}")
        
        # We have gathered all the information. Call Firebase Test Lab to start the job now
        matrix_id = ftl_service.start_job(params[:test_ios],
                                          gcp_project,
                                          app_gcs_link,
                                          test_app_gcs_link,
                                          result_storage,
                                          params[:devices],
                                          params[:timeout_sec],
                                          params[:disable_video_recording],
                                          params[:disable_performance_metrics],
                                          params[:gcp_additional_client_info],
                                          params[:xcode_version],
                                          params[:retry_if_failed],
                                          params[:android_test_target])

        # In theory, matrix_id should be available. Keep it to catch unexpected Firebase Test Lab API response
        if matrix_id.nil?
          UI.abort_with_message!("No matrix ID received.")
        end
        UI.message("Matrix ID for this submission: #{matrix_id}")
        return wait_for_test_results(ftl_service, gcp_project, matrix_id, params, result_storage, params[:print_successful_test])
      end

      def self.upload_file(app_path, bucket_name, gcs_path, gcp_project, gcp_credential, gcp_requests_timeout)
        file_name = "gs://#{bucket_name}/#{gcs_path}"
        storage = Fastlane::FirebaseTestLab::Storage.new(gcp_project, gcp_credential, gcp_requests_timeout)
        storage.upload_file(File.expand_path(app_path), bucket_name, gcs_path)
        return file_name
      end

      def self.wait_for_test_results(ftl_service, gcp_project, matrix_id, params, result_storage, print_successful_test)
        firebase_console_link = nil

        spinner = TTY::Spinner.new("[:spinner] Starting tests...", format: :dots)
        spinner.auto_spin

        # Keep pulling test results until they are ready
        loop do
          results = ftl_service.get_matrix_results(gcp_project, matrix_id)

          if firebase_console_link.nil?
            history_id, execution_id = try_get_history_id_and_execution_id(results)
            # Once we get the Firebase console link, we display that exactly once
            unless history_id.nil? || execution_id.nil?
              firebase_console_link = "https://console.firebase.google.com" \
                "/project/#{gcp_project}/testlab/histories/#{history_id}/matrices/#{execution_id}"

              spinner.success("Done")
              UI.message("Go to #{firebase_console_link} for more information about this run")

              if params[:async]
                UI.success("Job(s) have been submitted to Firebase Test Lab")
                return
              end

              spinner = TTY::Spinner.new("[:spinner]", format: :dots)
              spinner.auto_spin
            end
          end

          state = results["state"]
          # Handle all known error statuses
          if FirebaseTestLab::ERROR_STATE_TO_MESSAGE.key?(state.to_sym)
            spinner.error("Failed")
            invalid_matrix_details = results["invalidMatrixDetails"]
            if invalid_matrix_details &&
               FirebaseTestLab::INVALID_MATRIX_DETAIL_TO_MESSAGE.key?(invalid_matrix_details.to_sym)
              UI.error(FirebaseTestLab::INVALID_MATRIX_DETAIL_TO_MESSAGE[invalid_matrix_details.to_sym])
            end
            UI.user_error!(FirebaseTestLab::ERROR_STATE_TO_MESSAGE[state.to_sym])
          end

          if state == "FINISHED"
            spinner.success("Done")
            # Inspect the execution results: only contain info on whether each job finishes.
            # Do not include whether tests fail
            executions_completed = extract_execution_results(results)

            if results["resultStorage"].nil? || results["resultStorage"]["toolResultsExecution"].nil?
              UI.abort_with_message!("Unexpected response from Firebase test lab: Cannot retrieve result info")
            end

            # Now, look at the actual test result and see if they succeed
            history_id, execution_id = try_get_history_id_and_execution_id(results)
            if history_id.nil? || execution_id.nil?
              UI.abort_with_message!("Unexpected response from Firebase test lab: No history or execution ID")
            end
            test_results = ftl_service.get_execution_steps(gcp_project, history_id, execution_id)
            tests_successful, resultsDictionary = extract_test_results(ftl_service, test_results, gcp_project, history_id, execution_id, print_successful_test)
            download_files(result_storage, params)
            resultsDictionary["Time started"] = Time.parse(results["timestamp"]).strftime("%H:%M UTC")
            resultsDictionary["Firebase Test Lab link"] = "Go to <#{firebase_console_link}|Firebase console> for more information about this run"
            unless executions_completed && tests_successful
              UI.test_failure!(resultsDictionary)
            end
            return resultsDictionary
          end

          # We should have caught all known states here. If the state is not one of them, this
          # plugin should be modified to handle that
          unless RUNNING_STATES.include?(state)
            spinner.error("Failed")
            UI.abort_with_message!("The test execution is in an unknown state: #{state}. " \
              "We appreciate if you could notify us at " \
              "https://github.com/fastlane/fastlane-plugin-firebase_test_lab/issues")
          end
          sleep(PULL_RESULT_INTERVAL)
        end
      end

      def self.generate_directory_name
        timestamp = Time.now.getutc.strftime("%Y%m%d-%H%M%SZ")
        return "fastlane-#{timestamp}-#{SecureRandom.hex[0..5]}"
      end

      def self.try_get_history_id_and_execution_id(matrix_results)
        if matrix_results["resultStorage"].nil? || matrix_results["resultStorage"]["toolResultsExecution"].nil?
          return nil, nil
        end

        tool_results_execution = matrix_results["resultStorage"]["toolResultsExecution"]
        history_id = tool_results_execution["historyId"]
        execution_id = tool_results_execution["executionId"]
        return history_id, execution_id
      end

      def self.extract_execution_results(execution_results)
        UI.message("Test job(s) are finalized")
        UI.message("-------------------------")
        UI.message("|   EXECUTION RESULTS   |")
        failures = 0
        execution_results["testExecutions"].each do |execution|
          UI.message("-------------------------")
          execution_info = "#{execution['id']}: #{execution['state']}"
          if execution["state"] != "FINISHED"
            failures += 1
            UI.error(execution_info)
          else
            UI.success(execution_info)
          end

          # Display build logs
          if !execution["testDetails"].nil? && !execution["testDetails"]["progressMessages"].nil?
            execution["testDetails"]["progressMessages"].each { |msg| UI.message(msg) }
          end
        end

        UI.message("-------------------------")
        if failures > 0
          UI.error("😞  #{failures} execution(s) have failed to complete.")
        else
          UI.success("🎉  All jobs have ran and completed.")
        end
        return failures == 0
      end

      def self.extract_test_results(ftl_service, test_results, gcp_project, history_id, execution_id, print_successful_test)
        steps = test_results["steps"]
        failures = 0
        inconclusive_runs = 0
        resultsDictionary = {}        

        UI.message("-------------------------")
        UI.message("|      TEST OUTCOME     |")
        steps.each do |step|
          UI.message("-------------------------")
          step_id = step["stepId"]
          UI.message("Test step: #{step_id}")

          device = ""
          dimensionValues = step["dimensionValue"]
          dimensionValues.each do |dimensionValue|
            value = dimensionValue["value"]
            device += value + " "
          end
          device.strip()
          UI.message("#{device}")

          test_cases = ftl_service.get_execution_test_cases(gcp_project, history_id, execution_id, step_id)

          totalNrOfTest = 0
          totalNrOfSuccessfulTest = 0
          testCaseSummary = ""
          testCases = test_cases["testCases"]
          if !testCases.nil?
            testCases.each do |testCase|
              name = testCase["testCaseReference"]["name"]
              status = testCase["status"]
              if status.nil?
                totalNrOfTest = totalNrOfTest + 1
                totalNrOfSuccessfulTest = totalNrOfSuccessfulTest + 1
                if print_successful_test
                  testCaseSummary += "✅ " + name + "\n"
                end
              else 
                if status != "skipped"
                  totalNrOfTest = totalNrOfTest + 1
                  testCaseSummary += "🔥 " + name + "\n"
                end  
              end
            end
          else 
            testCaseSummary += ":question: No test cases :question:"
          end
          UI.message(testCaseSummary)

          testProcessDurationSeconds = step["testExecutionStep"]["testTiming"]["testProcessDuration"]["seconds"] || 0
          msgTestTime = "⏳ Test: #{testProcessDurationSeconds.to_i / 60} min #{testProcessDurationSeconds.to_i % 60} sec"
          UI.message(msgTestTime)
          runDurationSeconds = step["runDuration"]["seconds"] || 0
          msgTotalTime = "⌛️ Total: #{runDurationSeconds.to_i / 60} min #{runDurationSeconds.to_i % 60} sec"
          UI.message(msgTotalTime)

          outcome = step["outcome"]["summary"]
          case outcome
          when "success"
            UI.success("Result: #{outcome}")
          when "skipped"
            UI.message("Result: #{outcome}")
          when "inconclusive"
            inconclusive_runs += 1
            UI.error("Result: #{outcome}")
          when "failure"
            failures += 1
            UI.error("Result: #{outcome}")
          end
          totalTestRuns = "Tests run: #{totalNrOfSuccessfulTest}/#{totalNrOfTest}"
          if totalNrOfTest > 0 && totalNrOfSuccessfulTest == totalNrOfTest
            totalTestRuns = "✅ #{totalTestRuns}, *100% success*."
          else
            percentage = totalNrOfSuccessfulTest * 100 / totalNrOfTest
            totalTestRuns = ":warning: #{totalTestRuns}, *#{percentage}% success*."
          end  
          resultsDictionary["#{device}"] = "#{totalTestRuns}\n#{msgTestTime} #{msgTotalTime}.\n#{testCaseSummary}"
          UI.message("For details, go to https://console.firebase.google.com/project/#{gcp_project}/testlab/" \
            "histories/#{history_id}/matrices/#{execution_id}/executions/#{step_id}")
        end

        UI.message("-------------------------")
        if failures == 0 && inconclusive_runs == 0
          UI.success("🎉  Yay! All executions are completed successfully!")
        end
        if failures > 0
          UI.error("😞  #{failures} step(s) have failed.")
        end
        if inconclusive_runs > 0
          UI.error("😞  #{inconclusive_runs} step(s) yielded inconclusive outcomes.")
        end
        return (failures == 0 && inconclusive_runs == 0), resultsDictionary
      end

      def self.download_files(result_storage, params)
        @test_console_folderlist_output_file = "folderlist.txt"

        if params[:download_results_from_firebase]
          UI.message("Create firebase directory (if not exists) to store test results.")
          FileUtils.mkdir_p(params[:output_dir])

          if params[:download_file_list] && !params[:download_file_list].empty?
            UI.message("Get files at bucket...")

            params[:download_results_from_firebase] = false

            Action.sh("#{Fastlane::Commands.list_object} "\
                      "#{result_storage} "\
                      "| grep -e '/$' > #{@test_console_folderlist_output_file}")

            bucket_path = result_storage.delete_prefix("gs://")

            device_folders = []
            File.open(@test_console_folderlist_output_file).each do |line|
              folder = line.match(%r{#{bucket_path}/(.*)/$}).captures.first
              device_folders.push(folder)
            end

            defined_download_files = params[:download_file_list].split(" ")

            device_folders.each do |devicefolder|
              defined_download_files.each do |filename|
                UI.message("Download file '#{filename}' from '#{devicefolder}' to '#{params[:output_dir]}/#{devicefolder}/#{filename}'...")
                Action.sh("#{Fastlane::Commands.download_single_file} #{result_storage}/#{devicefolder}/#{filename} #{params[:output_dir]}/#{devicefolder}/#{filename}")
              end
            end
          else
            UI.message("Downloading instrumentation test results from Firebase Test Lab...")
            Action.sh("#{Fastlane::Commands.download_results} #{result_storage} #{params[:output_dir]}")
          end
        end
      end

      #####################################################
      # @!group Documentation
      #####################################################

      def self.description
        "Submit an test job to Firebase Test Lab"
      end

      def self.available_options
        Fastlane::FirebaseTestLab::Options.available_options
      end

      def self.authors
        ["powerivq"]
      end

      def self.is_supported?(platform)
        [:ios, :android].include?(platform)
      end
    end
  end
end
