module Puppet
  newtype(:schedule) do
    @doc = <<-EOT
      Define schedules for Puppet. Resources can be limited to a schedule by using the
      [`schedule`](http://docs.puppetlabs.com/references/latest/metaparameter.html#schedule)
      metaparameter.

      Currently, **schedules can only be used to stop a resource from being
      applied;** they cannot cause a resource to be applied when it otherwise
      wouldn't be, and they cannot accurately specify a time when a resource
      should run.

      Every time Puppet applies its configuration, it will apply the
      set of resources whose schedule does not eliminate them from
      running right then, but there is currently no system in place to
      guarantee that a given resource runs at a given time.  If you
      specify a very  restrictive schedule and Puppet happens to run at a
      time within that schedule, then the resources will get applied;
      otherwise, that work may never get done.

      Thus, it is advisable to use wider scheduling (e.g., over a couple of
      hours) combined with periods and repetitions.  For instance, if you
      wanted to restrict certain resources to only running once, between
      the hours of two and 4 AM, then you would use this schedule:

          schedule { 'maint':
            range  => "2 - 4",
            period => daily,
            repeat => 1,
          }

      With this schedule, the first time that Puppet runs between 2 and 4 AM,
      all resources with this schedule will get applied, but they won't
      get applied again between 2 and 4 because they will have already
      run once that day, and they won't get applied outside that schedule
      because they will be outside the scheduled range.

      Puppet automatically creates a schedule for each of the valid periods
      with the same name as that period (e.g., hourly and daily).
      Additionally, a schedule named `puppet` is created and used as the
      default, with the following attributes:

          schedule { 'puppet':
            period => hourly,
            repeat => 2,
          }

      This will cause resources to be applied every 30 minutes by default.
      EOT

    apply_to_all

    newparam(:name) do
      desc <<-EOT
        The name of the schedule.  This name is used to retrieve the
        schedule when assigning it to an object:

            schedule { 'daily':
              period => daily,
              range  => "2 - 4",
            }

            exec { "/usr/bin/apt-get update":
              schedule => 'daily',
            }

        EOT
      isnamevar
    end

    newparam(:range) do
      desc <<-EOT
        The earliest and latest that a resource can be applied.  This is
        always a hyphen-separated range within a 24 hour period, and hours
        must be specified in numbers between 0 and 23, inclusive.  Minutes and
        seconds can optionally be provided, using the normal colon as a
        separator. For instance:

            schedule { 'maintenance':
              range => "1:30 - 4:30",
            }

        This is mostly useful for restricting certain resources to being
        applied in maintenance windows or during off-peak hours. Multiple
        ranges can be applied in array context.
      EOT

      # This is lame; properties all use arrays as values, but parameters don't.
      # That's going to hurt eventually.
      validate do |values|
        values = [values] unless values.is_a?(Array)
        values.each { |value|
          unless  value.is_a?(String) and
              value =~ /\d+(:\d+){0,2}\s*-\s*\d+(:\d+){0,2}/
            self.fail "Invalid range value '#{value}'"
          end
        }
      end

      munge do |values|
        values = [values] unless values.is_a?(Array)
        ret = []

        values.each { |value|
          range = []
          # Split each range value into a hour, minute, second triad
          value.split(/\s*-\s*/).each { |val|
            # Add the values as an array.
            range << val.split(":").collect { |n| n.to_i }
          }

          self.fail "Invalid range #{value}" if range.length != 2

          # Make sure the hours are valid
          [range[0][0], range[1][0]].each do |n|
            raise ArgumentError, "Invalid hour '#{n}'" if n < 0 or n > 23
          end

          [range[0][1], range[1][1]].each do |n|
            raise ArgumentError, "Invalid minute '#{n}'" if n and (n < 0 or n > 59)
          end
          if range[0][0] > range[1][0]
            self.fail(("Invalid range #{value}; ") +
              "ranges cannot span days."
            )
          end
          ret << range
        }

        # Now our array of arrays
        ret
      end

      def match?(previous, now)
        # The lowest-level array is of the hour, minute, second triad
        # then it's an array of two of those, to present the limits
        # then it's array of those ranges
        @value = [@value] unless @value[0][0].is_a?(Array)

        @value.each do |value|
          limits = value.collect do |range|
            ary = [now.year, now.month, now.day, range[0]]
            if range[1]
              ary << range[1]
            else
              ary << now.min
            end

            if range[2]
              ary << range[2]
            else
              ary << now.sec
            end

            time = Time.local(*ary)

            unless time.hour == range[0]
              self.devfail(
                "Incorrectly converted time: #{time}: #{time.hour} vs #{range[0]}"
              )
            end

            time
          end

          unless limits[0] < limits[1]
            self.info(
            "Assuming upper limit should be that time the next day"
            )

            ary = limits[1].to_a
            ary[3] += 1
            limits[1] = Time.local(*ary)

            #self.devfail("Lower limit is above higher limit: %s" %
            #    limits.inspect
            #)
          end

          #self.info limits.inspect
          #self.notice now
          return true if now.between?(*limits)
        end

        # Else, return false, since our current time isn't between
        # any valid times
        false
      end
    end

    newparam(:periodmatch) do
      desc "Whether periods should be matched by number (e.g., the two times
        are in the same hour) or by distance (e.g., the two times are
        60 minutes apart)."

      newvalues(:number, :distance)

      defaultto :distance
    end

    newparam(:period) do
      desc <<-EOT
        The period of repetition for a resource. The default is for a resource
        to get applied every time Puppet runs.

        Note that the period defines how often a given resource will get
        applied but not when; if you would like to restrict the hours
        that a given resource can be applied (e.g., only at night during
        a maintenance window), then use the `range` attribute.

        If the provided periods are not sufficient, you can provide a
        value to the *repeat* attribute, which will cause Puppet to
        schedule the affected resources evenly in the period the
        specified number of times.  Take this schedule:

            schedule { 'veryoften':
              period => hourly,
              repeat => 6,
            }

        This can cause Puppet to apply that resource up to every 10 minutes.

        At the moment, Puppet cannot guarantee that level of
        repetition; that is, it can run up to every 10 minutes, but
        internal factors might prevent it from actually running that
        often (e.g., long-running Puppet runs will squash conflictingly scheduled runs).

        See the `periodmatch` attribute for tuning whether to match
        times by their distance apart or by their specific value.
      EOT

      newvalues(:hourly, :daily, :weekly, :monthly, :never)

      ScheduleScales = {
        :hourly => 3600,
        :daily => 86400,
        :weekly => 604800,
        :monthly => 2592000
      }
      ScheduleMethods = {
        :hourly => :hour,
        :daily => :day,
        :monthly => :month,
        :weekly => proc do |prev, now|
          # Run the resource if the previous day was after this weekday (e.g., prev is wed, current is tue)
          # or if it's been more than a week since we ran
          prev.wday > now.wday or (now - prev) > (24 * 3600 * 7)
        end
      }

      def match?(previous, now)
        return false if value == :never

        value = self.value
        case @resource[:periodmatch]
        when :number
          method = ScheduleMethods[value]
          if method.is_a?(Proc)
            return method.call(previous, now)
          else
            # We negate it, because if they're equal we don't run
            return now.send(method) != previous.send(method)
          end
        when :distance
          scale = ScheduleScales[value]

          # If the number of seconds between the two times is greater
          # than the unit of time, we match.  We divide the scale
          # by the repeat, so that we'll repeat that often within
          # the scale.
          diff = (now.to_i - previous.to_i)
          comparison = (scale / @resource[:repeat])

          return (now.to_i - previous.to_i) >= (scale / @resource[:repeat])
        end
      end
    end

    newparam(:repeat) do
      desc "How often a given resource may be applied in this schedule's `period`.
        Defaults to 1; must be an integer."

      defaultto 1

      validate do |value|
        unless value.is_a?(Integer) or value =~ /^\d+$/
          raise Puppet::Error,
            "Repeat must be a number"
        end

        # This implicitly assumes that 'periodmatch' is distance -- that
        # is, if there's no value, we assume it's a valid value.
        return unless @resource[:periodmatch]

        if value != 1 and @resource[:periodmatch] != :distance
          raise Puppet::Error,
            "Repeat must be 1 unless periodmatch is 'distance', not '#{@resource[:periodmatch]}'"
        end
      end

      munge do |value|
        value = Integer(value) unless value.is_a?(Integer)

        value
      end

      def match?(previous, now)
        true
      end
    end

    newparam(:weekday) do
      desc "The days of the week in which the schedule should be valid.
        You may specify the full day name (Tuesday), the three character
        abbreviation (Tue), or a number corresponding to the day of the
        week where 0 is Sunday, 1 is Monday, etc. You may pass an array
        to specify multiple days. If not specified, the day of the week
        will not be considered in the schedule."

      validate do |values|
        values = [values] unless values.is_a?(Array)
        values.each { |value|
          unless value.is_a?(String) and
              (value =~ /^[0-6]$/ or value =~ /^(Mon|Tues?|Wed(?:nes)?|Thu(?:rs)?|Fri|Sat(?:ur)?|Sun)(day)?$/i)
            raise ArgumentError, "%s is not a valid day of the week" % value
          end
        }
      end

      weekdays = {
        'sun' => 0,
        'mon' => 1,
        'tue' => 2,
        'wed' => 3,
        'thu' => 4,
        'fri' => 5,
        'sat' => 6,
      }

      munge do |values|
        values = [values] unless values.is_a?(Array)
        ret = {}

        values.each { |value|
           if value =~ /^[0-6]$/
              index = value.to_i
           else
              index = weekdays[value[0,3].downcase]
           end
            ret[index] = true
        }
        ret
      end

      def match?(previous, now)
        return true if value.has_key?(now.wday)
        false
      end
    end

    def self.instances
      []
    end

    def self.mkdefaultschedules
      result = []
      Puppet.debug "Creating default schedules"

            result << self.new(

        :name => "puppet",
        :period => :hourly,

        :repeat => "2"
      )

      # And then one for every period
      @parameters.find { |p| p.name == :period }.value_collection.values.each { |value|

              result << self.new(
          :name => value.to_s,
          :period => value
        )
      }

      result
    end

    def match?(previous = nil, now = nil)

      # If we've got a value, then convert it to a Time instance
      previous &&= Time.at(previous)

      now ||= Time.now

      # Pull them in order
      self.class.allattrs.each { |param|
        if @parameters.include?(param) and
          @parameters[param].respond_to?(:match?)
          return false unless @parameters[param].match?(previous, now)
        end
      }

      # If we haven't returned false, then return true; in other words,
      # any provided schedules need to all match
      true
    end
  end
end
