#--
# This file is part of Sonic Pi: http://sonic-pi.net
# Full project source: https://github.com/samaaron/sonic-pi
# License: https://github.com/samaaron/sonic-pi/blob/master/LICENSE.md
#
# Copyright 2013, 2014 by Sam Aaron (http://sam.aaron.name).
# All rights reserved.
#
# Permission is granted for use, copying, modification, distribution,
# and distribution of modified versions of this work as long as this
# notice is included.
#++
require_relative "util"
require_relative "studio"
require_relative "incomingevents"
require_relative "counter"
require_relative "promise"
require_relative "jobs"
require_relative "mods/spmidi"
#require_relative "mods/graphics"
require_relative "mods/sound"
#require_relative "mods/feeds"
#require_relative "mods/globalkeys"

require 'thread'
require 'fileutils'
require 'set'

module SonicPi
  class Spider

    attr_reader :event_queue

    def initialize(hostname, port, msg_queue, max_concurrent_synths)
      @msg_queue = msg_queue
      @event_queue = Queue.new
      @keypress_handlers = {}
      __message "Starting..."
      @events = IncomingEvents.new
      @sync_counter = Counter.new
      @job_counter = Counter.new
      @job_subthreads = {}
      @job_subthread_mutex = Mutex.new
      @user_jobs = Jobs.new
      @random_generator = Random.new(0)

      @event_t = Thread.new do
        loop do
          event = @event_queue.pop
          __handle_event event
        end
      end
    end

    #These includes must happen after the initialize method
    #as they may potentially redefine it to extend behaviour
    include SonicPi::Mods::SPMIDI
#    include SonicPi::Mods::Graphics
    include SonicPi::Mods::Sound
#    include SonicPi::Mods::Feeds
#    include SonicPi::Mods::GlobalKeys

    def on_keypress(&block)
      @keypress_handlers[:foo] = block
    end

    def print(output)
      __message output
    end

    def puts(output)
      __message output
    end

    def rand(limit=1.0)
      @random_generator.rand(limit)
    end

    def sleep(seconds)
      last = Thread.current.thread_variable_get :sonic_pi_spider_time
      now = Time.now

      new_t = last + seconds
      if now > new_t
        __message "Can't keep up..."
      else
        Kernel.sleep new_t - now
      end

      Thread.current.thread_variable_set :sonic_pi_spider_time, new_t
    end

    def sync(sync_id, val = nil)
      __no_kill_block do
        @events.event("/spider_thread_sync/" + sync_id.to_s, {:time => Thread.current.thread_variable_get(:sonic_pi_spider_time), :val => val})
      end
    end

    def wait(sync_id)
      p = Promise.new
      @events.oneshot_handler("/spider_thread_sync/" + sync_id.to_s) do |payload|
        p.deliver! payload
      end
      payload = p.get
      time = payload[:time]
      val = payload[:val]
      Thread.current.thread_variable_set :sonic_pi_spider_time, time
      val
    end

    def in_thread(&block)
      parent_t = Thread.current

      # Get copy of thread locals whilst we're sure they're not being modified
      # as we're in the thread parent_t
      parent_t_vars = {}
      parent_t.thread_variables.each do |v|
        parent_t_vars[v] = parent_t.thread_variable_get(v)
      end

      job_id = __current_job_id
      reg_with_parent_completed = Promise.new

      # Create the new thread
      t = Thread.new do

        # Synchronise on the promise. This means that we block this new
        # thread until we're absolutly sure it's been registered with
        # the parent thread as a thread local var
        reg_with_parent_completed.get

        # Attempt to associate the current thread with job with
        # job_id. This will kill the current thread if job is no longer
        # running.
        job_subthread_add(job_id, Thread.current)

        # Copy thread locals across from parent thread to this new thread
        parent_t_vars.each do |k,v|
          Thread.current.thread_variable_set(k, v)
        end

        # Reset subthreads thread local to the empty set. This shouldn't
        # be inherited from the parent thread.
        Thread.current.thread_variable_set :sonic_pi_spider_subthreads, Set.new

        # Give new thread a new subthread mutex
        Thread.current.thread_variable_set :sonic_pi_spider_subthread_mutex, Mutex.new

        # Give new thread a new no_kill mutex
        Thread.current.thread_variable_set :sonic_pi_spider_no_kill_mutex, Mutex.new

        # Actually run the thread code specified by the user!
        block.call

        # Disassociate thread with job as it has now finished
        job_subthread_rm(job_id, Thread.current)

        parent_t.thread_variable_get(:sonic_pi_spider_subthread_mutex).synchronize do
          parent_t.thread_variable_get(:sonic_pi_spider_subthreads).delete(Thread.current)
        end
      end

      # Whilst we know that the new thread is waiting on the promise to
      # be delivered, we can now add it to our list of subthreads. Using
      # the promise means that we can be assured that killing this
      # current thread won't create a zombie child thread as the child
      # thread will only continue exiting after it has been sucessfully
      # registered.

      parent_t.thread_variable_get(:sonic_pi_spider_subthread_mutex).synchronize do
        subthreads = parent_t.thread_variable_get :sonic_pi_spider_subthreads
        subthreads.add(t)
      end

      # Allow the subthread to continue running
      reg_with_parent_completed.deliver! true

      # Return subthread
      t
    end

    ## Not officially part of the API
    ## Probably should be moved somewhere else

    def __no_kill_block(&block)
      Thread.current.thread_variable_get(:sonic_pi_spider_no_kill_mutex).synchronize do
        block.call
      end
    end

    def __message(s)
      @msg_queue.push({:type => :message, :val => s.to_s, :jobid => __current_job_id, :jobinfo => __current_job_info})
    end

    def __current_job_id
      Thread.current.thread_variable_get :sonic_pi_spider_job_id
    end

    def __current_job_info
      Thread.current.thread_variable_get :sonic_pi_spider_job_info
    end

    def __sync_msg_command(msg)
      id = @sync_counter.next
      prom = Promise.new
      @events.add_handler("/sync", @events.gensym("/spider")) do |payload|
        if payload[:id] == id
          prom.deliver! payload[:result]
          :remove_handler
        end
      end
      msg[:sync] = id
      msg[:jobid] = __current_job_id
      msg[:jobinfo] = __current_job_info
      @msg_queue.push msg
      prom.get
    end

    def __handle_event(e)
      case e[:type]
      when :keypress
        @keypress_handlers.values.each{|h| h.call(e[:val])}
        else
          puts "Unknown event: #{e}"
        end
    end

    def __sync(id, res)
      @events.event("/sync", {:id => id, :result => res})
    end

    def __stop_job(j)
      __message "Stopping job #{j}"
      job_subthreads_kill(j)
      @user_jobs.kill_job j
      @events.event("/job-completed", {:id => j})
      @msg_queue.push({type: :job, jobid: j, action: :completed})
    end

    def __stop_jobs
      __message "Stopping all jobs."
      @user_jobs.each_id do |id|
        __stop_job id
      end
    end

    def __join_subthreads(t)
      subthreads = t.thread_variable_get :sonic_pi_spider_subthreads
      subthreads.each do |st|
        st.join
        __join_subthreads(st)
      end
    end

    def __spider_eval(code, info={})
      id = @job_counter.next
      job = Thread.new do
        begin
          reg_job(id)
          Thread.current.thread_variable_set :sonic_pi_spider_time, Time.now
          Thread.current.thread_variable_set :sonic_pi_spider_job_id, id
          Thread.current.thread_variable_set :sonic_pi_spider_job_info, info
          Thread.current.thread_variable_set :sonic_pi_spider_subthreads, Set.new
          Thread.current.thread_variable_set :sonic_pi_spider_subthread_mutex, Mutex.new
          Thread.current.thread_variable_set :sonic_pi_spider_no_kill_mutex, Mutex.new
          @msg_queue.push({type: :job, jobid: id, action: :start, jobinfo: info})
          eval(code)
          __join_subthreads(Thread.current)
          @events.event("/job-join", {:id => id})
          # wait until all synths are dead
          @user_jobs.job_completed(id)
          job_subthreads_kill(id)
          @events.event("/job-completed", {:id => id})
          @msg_queue.push({type: :job, jobid: id, action: :completed, jobinfo: info})
        rescue Exception => e
          @events.event("/job-join", {:id => id})
          @events.event("/job-completed", {:id => id})
          job_subthreads_kill(id)
          @user_jobs.job_completed(id)
          @msg_queue.push({type: :job, jobid: id, action: :completed, jobinfo: info})
          @msg_queue.push({type: :error, val: e.message, backtrace: e.backtrace, jobid: id  , jobinfo: info})
        end
      end

      @user_jobs.add_job(id, job, info)

    end

    def __exit
      __stop_jobs
      @msg_queue.push({:type => :exit, :jobid => __current_job_id, :jobinfo => __current_job_info})
      @event_t.kill

    end

    private

    def reg_job(job_id)
      @job_subthread_mutex.synchronize do
        @job_subthreads[job_id] = Set.new
      end
    end

    def job_subthread_add(job_id, t)
      @job_subthread_mutex.synchronize do
        return t.kill unless @job_subthreads[job_id]

        threads = @job_subthreads[job_id]
        @job_subthreads[job_id] = threads.add(t)
      end
    end

    def job_subthread_rm(job_id, t)
      @job_subthread_mutex.synchronize do
        threads = @job_subthreads[job_id]
        threads.delete(t) if threads
      end
    end

    def job_subthreads_kill(job_id)
      threads = @job_subthread_mutex.synchronize do
        threads = @job_subthreads[job_id]
        @job_subthreads.delete(job_id)
        threads
      end

      return :no_threads_to_kill unless threads

      threads.each do |t|
        t.thread_variable_get(:sonic_pi_spider_no_kill_mutex).synchronize do
          t.kill
        end
      end
    end
  end
end
