#!/usr/bin/ruby

#    Copyright (c) 2012, Simon Maynard
#    http://snmaynard.com
#    
#    Permission is hereby granted, free of charge, to any person obtaining a 
#    copy of this software and associated documentation files (the "Software"), 
#    to deal in the Software without restriction, including without limitation 
#    the rights to use, copy, modify, merge, publish, distribute, sublicense, 
#    and/or sell copies of the Software, and to permit persons to whom the 
#    Software is furnished to do so, subject to the following conditions:
#
#    The above copyright notice and this permission notice shall be included 
#    in all copies or substantial portions of the Software.
#
#    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
#    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
#    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
#    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, 
#    WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN 
#    CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

require 'bundler/setup'
require 'redis'

# Container class for stats around a key group
class KeyStats
  attr_accessor :total_instances, 
                :total_idle_time, 
                :total_serialized_length,
                :total_expirys_set,
                :min_serialized_length,
                :max_serialized_length,
                :min_idle_time,
                :max_idle_time,
                :max_ttl,
                :sample_keys
  
  def initialize
    @total_instances = 0
    @total_idle_time = 0
    @total_serialized_length = 0
    @total_expirys_set = 0
    
    @min_serialized_length = nil
    @max_serialized_length = nil
    @min_idle_time = nil
    @max_idle_time = nil
    @max_ttl = nil
    
    @sample_keys = {}
  end
  
  def add_stats_for_key(key, type, idle_time, serialized_length, ttl)
    @total_instances += 1
    @total_idle_time += idle_time
    @total_expirys_set += 1 if ttl != nil
    @total_serialized_length += serialized_length
    
    @min_idle_time = idle_time if @min_idle_time.nil? || @min_idle_time > idle_time
    @max_idle_time = idle_time if @max_idle_time.nil? || @max_idle_time < idle_time
    @min_serialized_length = serialized_length if @min_serialized_length.nil? || @min_serialized_length > serialized_length
    @max_serialized_length = serialized_length if @max_serialized_length.nil? || @max_serialized_length < serialized_length
    @max_ttl = ttl if ttl != nil && ( @max_ttl == nil || @max_ttl < ttl )
    
    @sample_keys[key] = type if @sample_keys.count < 10
  end
end

class RedisAudit
  @@key_regex = /^(.*):(.*)$/
  @@debug_regex = /serializedlength:(\d*).*lru_seconds_idle:(\d*)/
  
  # Configure regular expressions here if you need to guarantee that certain keys are grouped together
  @@key_group_regex_list = []
  
  def initialize(sample_size)
    @keys = Hash.new
    @sample_size = sample_size
    @dbsize = 0
  end
  
  def audit_keys(redis)
    @redis = redis
    dbsize = @redis.dbsize.to_i
    @dbsize = @dbsize + dbsize

    if @sample_size == 0
      @sample_size = (0.1 * dbsize).to_i
    end
    
    if @sample_size < dbsize
      puts "Sampling #{@sample_size} keys..."
      sample_progress = @sample_size/10
    
      @sample_size.times do |index|
        key = @redis.randomkey
        audit_key(key)
        if sample_progress > 0 && (index + 1) % sample_progress == 0
          puts "#{index + 1} keys sampled - #{(((index + 1)/@sample_size.to_f) * 100).round}% complete - #{Time.now}"
        end
      end
    else
      sample_progress = dbsize/10
      
      puts "Getting a list of all #{dbsize} keys..."
      keys = @redis.keys("*")
      puts "Auditing #{dbsize} keys..."
      keys.each_with_index do |key, index|
        audit_key(key)
        if sample_progress > 0 && (index + 1) % sample_progress == 0
          puts "#{index + 1} keys sampled - #{(((index + 1)/dbsize.to_f) * 100).round}% complete - #{Time.now}"
        end
      end
    end
  end
  
  def audit_key(key)
    pipeline = @redis.pipelined do
      @redis.debug("object", key)
      @redis.type(key)
      @redis.ttl(key)
    end
    debug_fields = @@debug_regex.match(pipeline[0])
    serialized_length = debug_fields[1].to_i
    idle_time = debug_fields[2].to_i
    type = pipeline[1]
    ttl = pipeline[2] == -1 ? nil : pipeline[2]
    @keys[group_key(key, type)] ||= KeyStats.new
    @keys[group_key(key, type)].add_stats_for_key(key, type, idle_time, serialized_length, ttl)
  rescue Redis::CommandError
    $stderr.puts "Skipping key #{key}"
  end
  
  # This function defines what keys are grouped together. Currently it looks for a key that
  # matches at least a third of the key from the start, and groups those together. It also 
  # removes any numbers as they are (generally) ids. 
  def group_key(key, type)
    @@key_group_regex_list.each_with_index do |regex, index|
      return "#{regex.to_s}:#{type}" if regex.match(key)
    end
    
    # This makes the odds of finding a correct match higher, as mostly these are ids
    key = key.delete("0-9")
    
    matching_key = nil
    length_of_best_match = 0
    
    @keys.keys.each do |current_key|
      length_of_match = 0
      
      current_key.length.times do |index|
        break if key[index] != current_key[index]
        length_of_match += 1
      end
      
      # Minimum length of match is 1/3 of the new key length
      if length_of_match >= key.length/3 && length_of_match > length_of_best_match && @@key_regex.match(current_key)[2] == type
        matching_key = current_key
        length_of_best_match = length_of_match
      end
    end
    if matching_key != nil
      return matching_key
    else
      return "#{key}:#{type}"
    end
  end
  
  def output_duration(seconds)
    m, s = seconds.divmod(60)
    h, m = m.divmod(60)
    d, h = h.divmod(24)
    
    output = []
    output << "#{d} days" if d != 0
    output << "#{h} hours" if h != 0
    output << "#{m} minutes" if m != 0
    output << "#{s} seconds" if s != 0
    return "0 seconds" if output.count == 0
    return output.join(", ") 
  end
  
  def output_bytes(bytes)
    kb, b = bytes.divmod(1024)
    mb, kb = kb.divmod(1024)
    gb, mb = mb.divmod(1024)
    
    if gb != 0
      result = ((gb + mb/1024.0)*100).round()/100.0
      return "#{result} GB"
    elsif mb != 0
      result = ((mb + kb/1024.0)*100).round()/100.0
      return "#{result} MB"
    elsif kb != 0
      result = ((kb + b/1024.0)*100).round()/100.0
      return "#{result} kB"
    else
      return "#{b} bytes"
    end
  end
  
  def output_stats
    complete_serialized_length = @keys.map {|key, value| value.total_serialized_length }.reduce(:+)
    sorted_keys = @keys.keys.sort{|a,b| @keys[a].total_serialized_length <=> @keys[b].total_serialized_length}
    
    puts "All DB has #{@dbsize} keys"
    puts "Sampled #{output_bytes(complete_serialized_length)} of Redis memory"
    puts
    puts "Found #{@keys.count} key groups"
    puts
    sorted_keys.each do |key|
      value = @keys[key]
      key_fields = @@key_regex.match(key)
      common_key = key_fields[1]
      common_type = key_fields[2]
      
      puts "=============================================================================="
      puts "Found #{value.total_instances} keys containing #{common_type}s, like:"
      puts "\e[0;33m#{value.sample_keys.keys.join(", ")}\e[0m"
      puts
      puts "These keys use \e[0;1;4m#{make_proportion_percentage(value.total_serialized_length/complete_serialized_length.to_f)}\e[0m of the total sampled memory (#{output_bytes(value.total_serialized_length)})"
      if value.total_expirys_set == 0
        puts "\e[0;1;4mNone\e[0m of these keys expire"
      else
        puts "\e[0;1;4m#{make_proportion_percentage(value.total_expirys_set/value.total_instances.to_f)}\e[0m of these keys expire (#{value.total_expirys_set}), with maximum ttl of #{output_duration(value.max_ttl)}"
      end
      
      puts "Average last accessed time: \e[0;1;4m#{output_duration(value.total_idle_time/value.total_instances)}\e[0m - (Max: #{output_duration(value.max_idle_time)} Min:#{output_duration(value.min_idle_time)})"
      puts
    end
    summary_columns = [{
      :title => "Key",
      :width => 50
    },{
      :title => "Memory Usage",
      :width => 12
    },{
      :title => "Expiry Proportion",
      :width => 17
    },{
      :title => "Last Access Time",
      :width => 50
    }]
    format = summary_columns.map{|c| "%-#{c[:width]}s" }.join(' | ')
    
    puts "=============================================================================="
    puts "Summary"
    puts
    puts format.tr(' |', '-+') % summary_columns.map{|c| '-'*c[:width] }
    puts format % summary_columns.map{|c| c[:title]}
    puts format.tr(' |', '-+') % summary_columns.map{|c| '-'*c[:width] }
    sorted_keys.reverse.each do |key|
      value = @keys[key]
      puts format % [value.sample_keys.keys[0][0...50], make_proportion_percentage(value.total_serialized_length/complete_serialized_length.to_f), make_proportion_percentage(value.total_expirys_set/value.total_instances.to_f), output_duration(value.min_idle_time)[0...50]]
    end
    puts format.tr(' |', '-+') % summary_columns.map{|c| '-'*c[:width] }
  end
  
  def make_proportion_percentage(value)
    return "#{(value * 10000).round/100.0}%"
  end
end

if ARGV.length < 2 || ARGV.length > 3
    puts "Usage: redis-audit.rb <host1:port;host2:port> <dbnum> <(optional)sample_size>"
    exit 1
end

hosts = ARGV[0].split(';')

db = ARGV[1].to_i
sample_size = ARGV[2].to_i

auditor = RedisAudit.new(sample_size)

hosts.each do |h|
    host = h.split(':')[0]
    port = h.split(':')[1].to_i
    redis = Redis.new(:host => host, :port => port, :db => db)
    puts "Auditing #{host}:#{port} db:#{db} sampling #{sample_size} keys"
    auditor.audit_keys(redis)
end

auditor.output_stats
