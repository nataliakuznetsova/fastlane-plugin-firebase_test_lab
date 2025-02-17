require 'googleauth'
require 'json'

require_relative './error_helper'
require_relative '../module'

module Fastlane
  module FirebaseTestLab
    class FirebaseTestLabService
      APIARY_ENDPOINT = "https://www.googleapis.com"
      TOOLRESULTS_GET_SETTINGS_API_V3 = "/toolresults/v1beta3/projects/{project}/settings"
      TOOLRESULTS_INITIALIZE_SETTINGS_API_V3 = "/toolresults/v1beta3/projects/{project}:initializeSettings"
      TOOLRESULTS_LIST_EXECUTION_API_V3 =
        "/toolresults/v1beta3/projects/{project}/histories/{history_id}/executions/{execution_id}"
      TOOLRESULTS_LIST_EXECUTION_STEP_API_V3 =
        TOOLRESULTS_LIST_EXECUTION_API_V3 + "/steps"
      TOOLRESULTS_LIST_EXECUTION_TEST_CASE_API_V3 =
        TOOLRESULTS_LIST_EXECUTION_STEP_API_V3 + "/{step_id}/testCases"

      FIREBASE_TEST_LAB_ENDPOINT = "https://testing.googleapis.com"
      FTL_CREATE_API = "/v1/projects/{project}/testMatrices"
      FTL_RESULTS_API = "/v1/projects/{project}/testMatrices/{matrix}"

      TESTLAB_OAUTH_SCOPES = ["https://www.googleapis.com/auth/cloud-platform"]

      private_constant :APIARY_ENDPOINT
      private_constant :TOOLRESULTS_GET_SETTINGS_API_V3
      private_constant :TOOLRESULTS_INITIALIZE_SETTINGS_API_V3
      private_constant :TOOLRESULTS_LIST_EXECUTION_API_V3
      private_constant :TOOLRESULTS_LIST_EXECUTION_STEP_API_V3
      private_constant :TOOLRESULTS_LIST_EXECUTION_TEST_CASE_API_V3
      private_constant :FIREBASE_TEST_LAB_ENDPOINT
      private_constant :FTL_CREATE_API
      private_constant :FTL_RESULTS_API
      private_constant :TESTLAB_OAUTH_SCOPES

      def initialize(credential)
        @auth = credential.get_google_credential(TESTLAB_OAUTH_SCOPES)
        @default_bucket = nil
      end

      def init_default_bucket(gcp_project)
        conn = Faraday.new(APIARY_ENDPOINT)
        begin
          conn.post(TOOLRESULTS_INITIALIZE_SETTINGS_API_V3.gsub("{project}", gcp_project)) do |req|
            req.headers = @auth.apply(req.headers)
            req.options.timeout = 15
            req.options.open_timeout = 5
          end
        rescue Faraday::Error => ex
          UI.abort_with_message!("Network error when initializing Firebase Test Lab, " \
            "type: #{ex.class}, message: #{ex.message}")
        end
      end

      def get_default_bucket(gcp_project)
        return @default_bucket unless @default_bucket.nil?

        init_default_bucket(gcp_project)
        conn = Faraday.new(APIARY_ENDPOINT)
        begin
          resp = conn.get(TOOLRESULTS_GET_SETTINGS_API_V3.gsub("{project}", gcp_project)) do |req|
            req.headers = @auth.apply(req.headers)
            req.options.timeout = 15
            req.options.open_timeout = 5
          end
        rescue Faraday::Error => ex
          UI.abort_with_message!("Network error when obtaining Firebase Test Lab default GCS bucket, " \
            "type: #{ex.class}, message: #{ex.message}")
        end

        if resp.status != 200
          FastlaneCore::UI.error("Failed to obtain default bucket for Firebase Test Lab.")
          summarized_error = ErrorHelper.summarize_google_error(resp.body)
          if summarized_error.include?("Not Authorized for project")
            FastlaneCore::UI.error("Please make sure that the account associated with your Google credential is the " \
                                   "project editor or owner. You can do this at the Google Developer Console " \
                                   "https://console.cloud.google.com/iam-admin/iam?project=#{gcp_project}")
          end
          FastlaneCore::UI.abort_with_message!(summarized_error)
          return nil
        else
          response_json = JSON.parse(resp.body)
          @default_bucket = response_json["defaultBucket"]
          return @default_bucket
        end
      end

      def start_job(test_ios, gcp_project, app_path, test_app_path, result_path, devices, timeout_sec, disable_video_recording, disable_performance_metrics, additional_client_info, xcode_version, retry_if_failed, android_test_target)
        if additional_client_info.nil? 
          additional_client_info = { version: VERSION }
        else
          additional_client_info["version"] = VERSION
        end
        additional_client_info = additional_client_info.map { |k,v| { key: k, value: v } }

        if retry_if_failed
          flaky_test_attempts = 1
        else
          flaky_test_attempts = 0
        end

        if test_ios
          ios_xc_test_hash = {
            testsZip: {
              gcsPath: app_path
            }
          }

          if !xcode_version.nil?
            ios_xc_test_hash.merge!({ xcodeVersion: xcode_version})
          end

          body = {
            projectId: gcp_project,
            testSpecification: {
              testTimeout: {
                seconds: timeout_sec
              },
              disableVideoRecording: disable_video_recording,
              disablePerformanceMetrics: disable_performance_metrics,
              iosTestSetup: {},
              iosXcTest: ios_xc_test_hash
            },
            environmentMatrix: {
              iosDeviceList: {
                iosDevices: devices.map(&FirebaseTestLabService.method(:map_ios_device_to_proto))
              }
            },
            resultStorage: {
              googleCloudStorage: {
                gcsPath: result_path
              }
            },
            flakyTestAttempts: flaky_test_attempts,
            clientInfo: {
              name: PLUGIN_NAME,
              clientInfoDetails: [
                additional_client_info
              ]
            }
          }
        else
          body = {
            projectId: gcp_project,
            testSpecification: {
              testTimeout: {
                seconds: timeout_sec,
              },
              disableVideoRecording: disable_video_recording,
              disablePerformanceMetrics: disable_performance_metrics,
              testSetup: {
                environmentVariables: [
                  { 
                    key: "clearPackageData",
                    value: "true"
                  }
                ]
              },
              androidInstrumentationTest: {
                appApk: {
                  gcsPath: app_path
                },
                testApk: {
                  gcsPath: test_app_path
                },
                orchestratorOption: "USE_ORCHESTRATOR",
                testTargets: [
                  android_test_target
                ]
              }
            },
            environmentMatrix: {
              androidDeviceList: {
                androidDevices: devices.map(&FirebaseTestLabService.method(:map_android_device_to_proto))
              }
            },
            resultStorage: {
              googleCloudStorage: {
                gcsPath: result_path
              }
            },
            flakyTestAttempts: flaky_test_attempts,
            clientInfo: {
              name: PLUGIN_NAME,
              clientInfoDetails: [
                additional_client_info
              ]
            }
          }
        end

        conn = Faraday.new(FIREBASE_TEST_LAB_ENDPOINT)
        begin
          resp = conn.post(FTL_CREATE_API.gsub("{project}", gcp_project)) do |req|
            req.headers = @auth.apply(req.headers)
            req.headers["Content-Type"] = "application/json"
            req.headers["X-Goog-User-Project"] = gcp_project
            req.body = body.to_json
            req.options.timeout = 15
            req.options.open_timeout = 5
          end
        rescue Faraday::Error => ex
          UI.abort_with_message!("Network error when initializing Firebase Test Lab, " \
            "type: #{ex.class}, message: #{ex.message}")
        end

        if resp.status != 200
          FastlaneCore::UI.error("Failed to start Firebase Test Lab jobs.")
          FastlaneCore::UI.abort_with_message!(ErrorHelper.summarize_google_error(resp.body))
        else
          response_json = JSON.parse(resp.body)
          return response_json["testMatrixId"]
        end
      end

      def get_matrix_results(gcp_project, matrix_id)
        url = FTL_RESULTS_API
              .gsub("{project}", gcp_project)
              .gsub("{matrix}", matrix_id)

        conn = Faraday.new(FIREBASE_TEST_LAB_ENDPOINT)
        begin
          resp = conn.get(url) do |req|
            req.headers = @auth.apply(req.headers)
            req.options.timeout = 15
            req.options.open_timeout = 5
          end
        rescue Faraday::Error => ex
          UI.abort_with_message!("Network error when attempting to get test results, " \
            "type: #{ex.class}, message: #{ex.message}")
        end

        if resp.status != 200
          FastlaneCore::UI.error("Failed to obtain test results.")
          FastlaneCore::UI.abort_with_message!(ErrorHelper.summarize_google_error(resp.body))
          return nil
        else
          return JSON.parse(resp.body)
        end
      end

      def get_execution_steps(gcp_project, history_id, execution_id)
        conn = Faraday.new(APIARY_ENDPOINT)
        url = TOOLRESULTS_LIST_EXECUTION_STEP_API_V3
              .gsub("{project}", gcp_project)
              .gsub("{history_id}", history_id)
              .gsub("{execution_id}", execution_id)
        begin
          resp = conn.get(url) do |req|
            req.headers = @auth.apply(req.headers)
            req.options.timeout = 15
            req.options.open_timeout = 5
          end
        rescue Faraday::Error => ex
          UI.abort_with_message!("Failed to obtain the metadata of test artifacts, " \
            "type: #{ex.class}, message: #{ex.message}")
        end

        if resp.status != 200
          FastlaneCore::UI.error("Failed to obtain the metadata of test artifacts.")
          FastlaneCore::UI.abort_with_message!(ErrorHelper.summarize_google_error(resp.body))
        end
        return JSON.parse(resp.body)
      end

      def get_execution_test_cases(gcp_project, history_id, execution_id, step_id)
        conn = Faraday.new(APIARY_ENDPOINT)
        url = TOOLRESULTS_LIST_EXECUTION_TEST_CASE_API_V3
              .gsub("{project}", gcp_project)
              .gsub("{history_id}", history_id)
              .gsub("{execution_id}", execution_id)
              .gsub("{step_id}", step_id) + "?pageSize=200"
        begin
          resp = conn.get(url) do |req|
            req.headers = @auth.apply(req.headers)
            req.options.timeout = 15
            req.options.open_timeout = 5
          end
        rescue Faraday::Error => ex
          UI.abort_with_message!("Failed to obtain the metadata of test artifacts, " \
            "type: #{ex.class}, message: #{ex.message}")
        end

        if resp.status != 200
          FastlaneCore::UI.error("Failed to obtain the metadata of test artifacts.")
          FastlaneCore::UI.abort_with_message!(ErrorHelper.summarize_google_error(resp.body))
        end
        return JSON.parse(resp.body)
      end

      def self.map_ios_device_to_proto(device)
        {
          iosModelId: device[:model],
          iosVersionId: device[:version],
          locale: device[:locale],
          orientation: device[:orientation]
        }
      end

      def self.map_android_device_to_proto(device)
        {
          androidModelId: device[:model],
          androidVersionId: device[:version],
          locale: device[:locale],
          orientation: device[:orientation]
        }
      end

    end
  end
end
