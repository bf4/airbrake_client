#!/usr/bin/env ruby
#v3 api
#https://airbrake.io/api/v3/projects?key=KEY
#https://airbrake.io/api/v3/projects/PROJECT_ID/groups?key=KEY
#https://airbrake.io/api/v3/projects/PROJECT_ID/groups/GROUP_ID?key=KEY
#https://airbrake.io/api/v3/projects/PROJECT_ID/groups/GROUP_ID/notices?key=KEY
#https://airbrake.io/api/v3/projects/PROJECT_ID/groups/GROUP_ID/last-notice?key=KEY
#https://airbrake.io/api/v3/projects/PROJECT_ID/group-environments?key=KEY
#https://airbrake.io/api/v3/projects/PROJECT_ID/deploys?key=KEY
#https://airbrake.io/api/v3/projects/PROJECT_ID/deploys/GROUP_ID?key=KEY
#https://help.airbrake.io/kb/api-2/notifier-api-v3
#v2 api
#https://help.airbrake.io/kb/api-2/api-overview
#https://SUBDOMAIN.airbrake.io/errors.xml?auth_token=KEY
#https://SUBDOMAIN.airbrake.io/errors/GROUP_ID.xml?auth_token=KEY
#https://github.com/spagalloco/airbrake-api
require 'open-uri'
require 'net/http'
require 'net/https'
require 'json'
class AirbrakeClient
  def initialize(key, project_id, options={:environment => 'production', :resolved => 'true'})
    @api_url_base = "https://airbrake.io/api/v3/projects/"
    @project_id = project_id
    @global_options =
      {
      :key => key,
      }.merge(options)
    @pages = {}
    @requested = []
  end
  def groups(page=1, error_types)
    next_page = @pages[page]
    request_options = {:start => next_page}
    return [] if next_page.nil? && page > 1
    return [] if @requested.include?(next_page)
    debug next_page
    @requested << next_page
    debug url = request_url('groups', request_options)
    response = make_request(url)
    case response.code.to_i
    when 200..299
      json = JSON.load(response.body)
      previous_notice       = json['start']
      # previous_notice_count = json['preceding']
      next_notice           = json['end']
      # next_notice_count     = json['succeeding']
      @pages[page + 1] = next_notice
      if @pages[page].nil?
        @pages[page] = previous_notice
      end
    # json['groups'].each
    # def last_notice_at
    #   notice['lastNoticeAt']
    # end
    # def notice_count
    #   notice['noticeCount']
    # end
    # def notice_total_count
    #   json['noticeTotalCount']
    # end
      groups = json['groups']
      errors = groups.select {|group|
        if error_types.empty?
          true
        else
          group['errors'].any? {|error|
            error_type = error['type']
            error_types.include?(error_type)
          }
        end
      }
      errors.map {|error| error['id'] }.to_a
    else
      fail "bad response #{response}"
    end
  end
  # https://airbrake.io/api/v3/projects/PROJECT_ID/groups?key=
  GroupNotice = Struct.new(:notice) do
    Error = Struct.new(:error) do
      BacktraceLine = Struct.new(:bcl) do
        def file; bcl['file']; end
        def function; bcl['function']; end
        def line; bcl['line']; end
        def column; bcl['column']; end
        def to_s
          "#{file}:#{line}:#{column}:::#{function}"
        end
      end
      def type
        error['type']
      end
      def message
        error['message']
      end
      def backtrace
        @backtrace ||= error['backtrace'].map {|bcl| BacktraceLine.new(bcl) }
      end
      def exception_source
        backtrace.find{|i|
          i.file.to_s.include?("[PROJECT_ROOT]") and not i.file.to_s.include?("vendor/bundle")
        }.to_s
      end
      def to_hash
        {
          type: type,
          message: message,
          backtrace: [backtrace.first.to_s, exception_source]
        }
      end
    end
    def context
      notice['context'].values_at 'environment', 'url', 'userAgent'
    end
    def errors
      @errors ||= notice['errors'].map {|e| Error.new(e) }
    end
    # production
    def environment
      notice['environment']
    end
    def session
      notice['session']
    end
    def params
      notice['params']
    end
    # date/time
    def created_at
      notice['createdAt']
    end
    # v1/balances
    def component
      notice['component']
    end
    # post_captcha
    def action
      notice['action']
    end
    # lastDeployId":0,
    # "lastDeployAt":"0001-01-01T00:00:00Z",
    # "lastNoticeId"
    # "id":661211461,
    # "projectId":91347,
    # "isGlobal":false,
    # "resolved":false,
    def to_hash
      {
        params: params,
        session: session,
        context: context,
        created_at: created_at,
        environment: environment,
        errors: errors.map(&:to_hash),
      }
    end
  end
  # https://airbrake.io/api/v3/projects/PROJECT_ID/groups/GROUP_ID/notices?key=
  def group_errors(group_id)
    url = request_url("groups/#{group_id}/notices")
    response = make_request(url)
    case response.code.to_i
    when 200..299
      json = JSON.load(response.body)
      # previous_notice       = json['start']
      # previous_notice_count = json['preceding']
      # next_notice           = json['end']
      # next_notice_count     = json['succeeding']
      notices = json['notices'].map {|n| GroupNotice.new(n) }
      notices.map {|notice|
        notice.to_hash
      }
    else
      fail "bad response #{response}"
    end
  end
  def make_request(url)
   #  puts "Making request to #{url}"
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    if http.use_ssl = (uri.scheme == 'https')
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end
    request = Net::HTTP::Get.new(uri.request_uri)
    http.request(request)
  end
  def request_url(path, options={:page => 1})
    params = {
      #  :groups_start => 'GROUP_HASH',
    }.
      merge(@global_options).
      merge(options).
      map {|k,v|
        "#{k}=#{v}"
    }.join("&")
    "#{@api_url_base}#{@project_id}/#{path}?#{params}"
  end

  def debug(msg='')
    p msg if @verbose
  end
end

if $0 == __FILE__
  require 'pp'
  range = (1..30)
  error_types = ARGV.to_a
  key = ENV.fetch('AIRBRAKE_API_KEY')
  project_id = ENV.fetch('PROJECT_ID') do
    fail 'missing PROJECT_ID'
  end
  project_name = ENV.fetch('PROJECT_NAME') { '' }

  puts "getting unresolved groups"
  client = AirbrakeClient.new(key, project_id, :resolved => 'false', :environment => 'production')
  unresolved_groups = range.flat_map {|page|
    print '.'
    client.groups(page, error_types)
  }.compact.uniq
  puts

  if ENV['INCLUDE_RESOLVED'] =~ /true/i
    puts "getting resolved groups"
    client = AirbrakeClient.new(key, project_id, :resolved => 'true', :environment => 'production')
    resolved_groups = range.flat_map {|page|
      print '.'
      client.groups(page, error_types)
    }.compact.uniq
    puts
    groups = resolved_groups | unresolved_groups
  else
    groups = unresolved_groups
  end
  puts "got groups #{groups}"

  puts "getting errors"
  require 'yaml'
  # https://airbrake.io/api/v3/projects/PROJECT_ID/groups/GROUP_ID/notices?key=
  GroupErrors = Struct.new(:hash) do
    Error = Struct.new(:hash) do
      def type
        hash[:type]
      end
      def message
        @message ||= hash[:message].
          gsub(/:0x[0-9a-f]+/, ":object_id").
          gsub(/([ (,]')[^']+('[ ),])/,'\1xstringx\2').
          gsub(/([ (,]")[^"]+("[ ),]) /,'\1xstringx\2').
          gsub(/([=><`]\s{1,3})\d+/, '\11number1')
      end
      def backtrace
        hash[:backtrace]
      end
      def identifier
        backtrace.inspect
      end
    end
    def params
        hash[:params].values_at("action", "controller")
    end
    def params_keys
      hash[:params].keys
    end
    def types
      errors.map(&:type).uniq
    end
    def errors
      @errors ||= hash[:errors].map {|e| Error.new(e) }
    end
    def created_at
      hash[:created_at]
    end
    def inspect
      "<GroupErrors: #{hash.inspect}>"
    end
  end
  if error_filter = ENV['ERROR_FILTER']
    ge_filter = ->(ge){ge.inspect =~ /#{error_filter}/o && ge }
  else
    ge_filter = ->(ge){ ge }
  end
  begin
    file = File.open("report.yml","w")
    errors_by_type = groups.flat_map { |group_id|
      client.group_errors(group_id).map{|e|
        ge_filter.(GroupErrors.new(e))
      }.compact
    }.group_by {|ge| ge.types.first }
  ensure
    file.close
  end

  @exceptions = Hash.new {|h,line| h[line] = [] } # Hash<line,Array<message>>
  @exception_stats  = Hash.new {|h,type| h[type] = [] } # Hash<type,Array<created_at>>
  puts "Max errors per type: #{range.size*2}"
  errors_by_type.each do |type, group_errors|
    puts
    puts "*"*8
    puts type
    @exception_stats[type].concat group_errors.map(&:created_at)
    group_errors.flat_map(&:errors).group_by(&:identifier).map do |trace, error|
      error.each do |e|
        first_line, first_app_line = e.backtrace
        source = first_app_line.empty? ? first_line : first_app_line
        @exceptions[source] << e.message
      end
      [error.count, trace, error.map(&:message).uniq]
    end.sort.reverse.each do |item|
      count, trace, messages = item
      puts %(\n#{count} errors: \n\t#{messages.map{|m| m[0..400] }.join("\n\t\t")}\n\t#{trace})
    end
  end
  puts
  output = "exceptions_#{project_id}#{'-' << project_name unless project_name.empty?}.txt"
  puts "Exceptions by source: #{output}"
  File.open(output, "w") do |io|
    @exceptions.sort {|(a,_),(b,_)| a.to_s <=> b.to_s }.each do |line, messages|
      io.puts "%s\t%s\t%s" % [
        line,
        messages.count,
        messages.compact.sort.uniq.inspect
      ]
    end
  end
  output = "exception_stats_#{project_id}#{'-' << project_name unless project_name.empty?}.txt"
  puts "Exceptions stats: #{output}"
  File.open(output, "w") do |io|
    @exception_stats.sort.each do |type, created_ats|
      first_notice, last_notice = created_ats.compact.sort.uniq.tap {|a| break [a.first, a.last] }
      io.puts "%s\t%s\t%s\t%s" % [type, created_ats.count, first_notice, last_notice]
    end
  end
end
