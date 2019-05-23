# Copyright 2015 EPAM Systems
# 
# 
# This file is part of Report Portal.
# 
# Report Portal is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# ReportPortal is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
# 
# You should have received a copy of the GNU Lesser General Public License
# along with Report Portal.  If not, see <http://www.gnu.org/licenses/>.

require 'json'
require 'rest_client'
require 'uri'
require 'pathname'
require 'tempfile'

require_relative 'report_portal/settings'
require_relative 'report_portal/patches/rest_client'
require_relative 'report_portal/patches/request'

module ReportPortal
  TestItem = Struct.new(:name, :type, :id, :start_time, :description, :closed, :tags)
  LOG_LEVELS = { error: 'ERROR', warn: 'WARN', info: 'INFO', debug: 'DEBUG', trace: 'TRACE', fatal: 'FATAL', unknown: 'UNKNOWN' }

  class << self
    attr_accessor :launch_id, :current_scenario, :last_used_time

    def now
      (Time.now.to_f * 1000).to_i
    end

    def status_to_level(status)
      case status
      when :passed
        LOG_LEVELS[:info]
      when :failed, :undefined, :pending, :error
        LOG_LEVELS[:error]
      when :skipped
        LOG_LEVELS[:warn]
      else
        LOG_LEVELS.fetch(status, LOG_LEVELS[:info])
      end
    end

    def launch_created
      @launch_id != "-1"
    end

    def start_launch(description, start_time = now)
      data = { name: Settings.instance.launch, start_time: start_time, tags: Settings.instance.tags, description: description, mode: Settings.instance.launch_mode }
      tries = 3
      max_tries = 3
      begin
        response = project_resource['launch'].post(data.to_json)
        @launch_id = JSON.parse(response)['id']
        $logger.info("[ReportPortal] Request to [launch] successful after #{(max_tries-tries)+1} attempts.") if tries != 3
      rescue Exception => _e
        $logger.warn("[ReportPortal] Request to [launch] produced an exception: #{$!.class}: #{$!}")
        # $!.backtrace.each(&method(:p))
        unless (tries -= 1).zero?
          $logger.warn("[ReportPortal] Waiting 10 seconds and retrying request to [launch], #{tries} attempts remaining.")
          sleep(10)
          retry
        end
        $logger.warn("[ReportPortal] Failed to execute request to [launch] after 3 attempts.")
        $logger.warn("[ReportPortal] Could not create a launch, no results will be sent to Report Portal.")
        @launch_id = "-1" # set launch_id to -1 since we could not access Report Portal, this should prevent all future calls to Report Portal
      end
      @launch_id
    end

    def finish_launch(end_time = now)
      data = { end_time: end_time }
      tries = 3
      max_tries = 3
      begin
        result = project_resource["launch/#{@launch_id}/finish"].put(data.to_json)
        $logger.info("[ReportPortal] Request to [launch/#{@launch_id}/finish] successful after #{(max_tries-tries)+1} attempts.") if tries != 3
        result
      rescue Exception => _e
        $logger.warn("[ReportPortal] Request to [launch/#{@launch_id}/finish] produced an exception: #{$!.class}: #{$!}")
        # $!.backtrace.each(&method(:p))
        unless (tries -= 1).zero?
          $logger.warn("[ReportPortal] Waiting 10 seconds and retrying request to [launch/#{@launch_id}/finish], #{tries} attempts remaining.")
          sleep(10)
          retry
        end
        $logger.warn("[ReportPortal] Failed to execute request to [launch/#{@launch_id}/finish] after 3 attempts.")
      end
    end

    def start_item(item_node)
      item = item_node.content
      data = { start_time: item.start_time, name: item.name[0, 255], type: item.type.to_s, launch_id: @launch_id, description: item.description }
      data[:tags] = item.tags unless item.tags.empty?
      retry_required = false
      begin
        url = 'item'
        url += "/#{item_node.parent.content.id}" unless item_node.parent && item_node.parent.is_root?
        response = project_resource[url].post(data.to_json)
        $logger.warn("[ReportPortal][***] Retry with time shifted [start_time] was required.") if retry_required
        JSON.parse(response)['id']
      rescue RestClient::Exception => e
        $logger.warn("[ReportPortal] Request to #{"item/#{item.id}"} produced an exception: #{$!.class}: #{$!}")
        response_message = JSON.parse(e.response)['message']
        m = response_message.match(/Start time of child \['(.+)'\] item should be same or later than start time \['(.+)'\] of the parent item\/launch '.+'/)
        if m
          $logger.warn("[ReportPortal] Shifting item [start_time] by 1 second is required.")
          time = Time.strptime(m[2], '%a %b %d %H:%M:%S %z %Y')
          data[:start_time] = (time.to_f * 1000).to_i + 1000
          ReportPortal.last_used_time = data[:start_time]
          retry_required = true
          retry
        else
          $logger.warn("[ReportPortal] Shifting item [start_time] is not required according to exception message.")
          # $!.backtrace.each(&method(:p))
          unless (tries -= 1).zero?
            $logger.warn("[ReportPortal] Waiting 10 seconds and retrying request to [#{"item/#{item.id}"}], #{tries} attempts remaining.")
            sleep(10)
            retry
          end
          $logger.warn("[ReportPortal] Failed to execute request to [#{"item/#{item.id}"}] after 3 attempts.")
        end

      rescue => _e
        $logger.warn("[ReportPortal] Request to #{"item/#{item.id}"} produced an exception: #{$!.class}: #{$!}")
        # $!.backtrace.each(&method(:p))
        unless (tries -= 1).zero?
          $logger.warn("[ReportPortal] Waiting 10 seconds and retrying request to [#{"item/#{item.id}"}], #{tries} attempts remaining.")
          sleep(10)
          retry
        end
        $logger.warn("[ReportPortal] Failed to execute request to [#{"item/#{item.id}"}] after 3 attempts.")
      end
    end

    def finish_item(item, status = nil, end_time = nil, force_issue = nil)
      unless item.nil? || item.id.nil? || item.closed
        data = { end_time: end_time.nil? ? now : end_time }
        data[:status] = status unless status.nil?
        if force_issue && status != :passed # TODO: check for :passed status is probably not needed
          data[:issue] = { issue_type: 'AUTOMATION_BUG', comment: force_issue.to_s }
        elsif status == :skipped
          data[:issue] = { issue_type: 'NOT_ISSUE' }
        end
        tries = 3
        max_tries = 3
        begin
          project_resource["item/#{item.id}"].put(data.to_json)
          $logger.info("[ReportPortal] Request to #{"item/#{item.id}"} successful after #{(max_tries-tries)+1} attempts.") if tries != 3
        rescue Exception => _e
          $logger.warn("[ReportPortal] Request to #{"item/#{item.id}"} produced an exception: #{$!.class}: #{$!}")
          # $!.backtrace.each(&method(:p))
          unless (tries -= 1).zero?
            $logger.warn("[ReportPortal] Waiting 10 seconds and retrying request to [#{"item/#{item.id}"}], #{tries} attempts remaining.")
            sleep(10)
            retry
          end
          $logger.warn("[ReportPortal] Failed to execute request to [#{"item/#{item.id}"}] after 3 attempts.")
        end
        item.closed = true
      end
    end

    def send_log(status, message, time)
      unless @current_scenario.nil? || @current_scenario.closed # it can be nil if scenario outline in expand mode is executed
        data = { item_id: @current_scenario.id, time: time, level: status_to_level(status), message: message.to_s }
        tries = 3
        max_tries = 3
        begin
          project_resource['log'].post(data.to_json)
          $logger.info("[ReportPortal] Request to [log] successful after #{(max_tries-tries)+1} attempts.") if tries != 3
        rescue Exception => _e
          $logger.warn("[ReportPortal] Request to [log] produced an exception: #{$!.class}: #{$!}")
          # $!.backtrace.each(&method(:p))
          unless (tries -= 1).zero?
            $logger.warn("[ReportPortal] Waiting 10 seconds and retrying request to [log], #{tries} attempts remaining.")
            sleep(10)
            retry
          end
          $logger.warn("[ReportPortal] Failed to execute request to [log] after 3 attempts.")
        end
      end
    end

    def send_file(status, path, label = nil, time = now, mime_type = 'image/png')
      unless File.file?(path)
        extension = ".#{MIME::Types[mime_type].first.extensions.first}"
        temp = Tempfile.open(['file',extension])
        temp.binmode
        temp.write(Base64.decode64(path))
        temp.rewind
        path = temp
      end
      File.open(File.realpath(path), 'rb') do |file|
        label ||= File.basename(file)
        json = { level: status_to_level(status), message: label, item_id: @current_scenario.id, time: time, file: { name: File.basename(file) } }
        data = { :json_request_part => [json].to_json, label => file, :multipart => true, :content_type => 'application/json' }
        tries = 3
        max_tries = 3
        begin
          project_resource['log'].post(data, content_type: 'multipart/form-data')
          $logger.info("[ReportPortal] Request to [log] successful after #{(max_tries-tries)+1} attempts.") if tries != 3
        rescue Exception => _e
          $logger.warn("[ReportPortal] Request to [log] produced an exception: #{$!.class}: #{$!}")
          # $!.backtrace.each(&method(:p))
          unless (tries -= 1).zero?
            $logger.warn("[ReportPortal] Waiting 10 seconds and retrying request to [log], #{tries} attempts remaining.")
            sleep(10)
            retry
          end
          $logger.warn("[ReportPortal] Failed to execute request to [log] after 3 attempts.")
        end
      end
    end

    # needed for parallel formatter
    def item_id_of(name, parent_node)
      if parent_node.is_root? # folder without parent folder
        url = "item?filter.eq.launch=#{@launch_id}&filter.eq.name=#{URI.escape(name)}&filter.size.path=0"
      else
        url = "item?filter.eq.launch=#{@launch_id}&filter.eq.parent=#{parent_node.content.id}&filter.eq.name=#{URI.escape(name)}"
      end
      tries = 3
      max_tries = 3
      begin
        data = JSON.parse(project_resource[url].get)
        $logger.info("[ReportPortal] Request to #{url} successful after #{(max_tries-tries)+1} attempts.") if tries != 3
        if data.key? 'content'
          data['content'].empty? ? nil : data['content'][0]['id']
        else
          nil # item isn't started yet
        end
      rescue Exception => _e
        $logger.warn("[ReportPortal] Request to #{url} produced an exception: #{$!.class}: #{$!}")
        # $!.backtrace.each(&method(:p))
        unless (tries -= 1).zero?
          $logger.warn("[ReportPortal] Waiting 10 seconds and retrying request to [#{url}], #{tries} attempts remaining.")
          sleep(10)
          retry
        end
        $logger.warn("[ReportPortal] Failed to execute request to #{url} after 3 attempts.")
        nil
      end
    end

    # needed for parallel formatter
    def close_child_items(parent_id)
      if parent_id.nil?
        url = "item?filter.eq.launch=#{@launch_id}&filter.size.path=0&page.page=1&page.size=100"
      else
        url = "item?filter.eq.launch=#{@launch_id}&filter.eq.parent=#{parent_id}&page.page=1&page.size=100"
      end
      ids = []
      loop do
        tries = 3
        max_tries = 3
        begin
          data = JSON.parse(project_resource[url].get)
          $logger.info("[ReportPortal] Request to #{url} successful after #{(max_tries-tries)+1} attempts.") if tries != 3
          if data.key?('links')
            link = data['links'].find { |i| i['rel'] == 'next' }
            url = link.nil? ? nil : link['href']
          else
            url = nil
          end
          data['content'].each do |i|
            ids << i['id'] if i['has_childs'] && i['status'] == 'IN_PROGRESS'
          end
          break if url.nil?
        rescue Exception => _e
          $logger.warn("[ReportPortal] Request to #{url} produced an exception: #{$!.class}: #{$!}")
          # $!.backtrace.each(&method(:p))
          unless (tries -= 1).zero?
            $logger.warn("[ReportPortal] Waiting 10 seconds and retrying request to [#{url}], #{tries} attempts remaining.")
            sleep(10)
            retry
          end
          $logger.warn("[ReportPortal] Failed to execute request to #{url} after 3 attempts.")
          nil
        end
      end

      ids.each do |id|
        close_child_items(id)
        # temporary, we actually only need the id
        finish_item(TestItem.new(nil, nil, id, nil, nil, nil, nil))
      end
    end

    private

    def project_resource
      options = {}
      options[:headers] = {
        :Authorization => "Bearer #{Settings.instance.uuid}",
        content_type: :json
      }
      verify_ssl = Settings.instance.disable_ssl_verification
      options[:verify_ssl] = !verify_ssl unless verify_ssl.nil?
      RestClient::Resource.new(Settings.instance.project_url, options) do |response, request, _, &block|
        # $logger.info("[ReportPortal] => URL: #{request.args[:url]} with #{request.args[:payload]}")
        unless (200..207).include?(response.code)
          $logger.warn("[ReportPortal] ReportPortal API returned #{response}")
          $logger.warn("[ReportPortal] Offending request method/URL: #{request.args[:method].upcase} #{request.args[:url]}")
          $logger.warn("[ReportPortal] Offending request payload: #{request.args[:payload]}}")
        end
        response.return!(&block)
      end
    end
  end
end
