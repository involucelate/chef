#
# Author:: Lamont Granquist (<lamont@chef.io>)
# Copyright:: Copyright (c) 2014 Chef Software, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

class Chef
  class NodeMap

    #
    # Create a new NodeMap
    #
    def initialize
      @map = {}
    end

    #
    # Set a key/value pair on the map with a filter.  The filter must be true
    # when applied to the node in order to retrieve the value.
    #
    # @param key [Object] Key to store
    # @param value [Object] Value associated with the key
    # @param filters [Hash] Node filter options to apply to key retrieval
    #
    # @yield [node] Arbitrary node filter as a block which takes a node argument
    #
    # @return [NodeMap] Returns self for possible chaining
    #
    def set(key, value, platform: nil, platform_version: nil, platform_family: nil, os: nil, on_platform: nil, on_platforms: nil, canonical: nil, override: nil, &block)
      Chef::Log.deprecation "The on_platform option to node_map has been deprecated" if on_platform
      Chef::Log.deprecation "The on_platforms option to node_map has been deprecated" if on_platforms
      platform ||= on_platform || on_platforms
      filters = {}
      filters[:platform] = platform if platform
      filters[:platform_version] = platform_version if platform_version
      filters[:platform_family] = platform_family if platform_family
      filters[:os] = os if os
      new_matcher = { filters: filters, block: block, value: value, canonical: canonical }
      @map[key] ||= []
      # Decide where to insert the matcher; the new value is preferred over
      # anything more specific (see `priority_of`) and is preferred over older
      # values of the same specificity.  (So all other things being equal,
      # newest wins.)
      insert_at = nil
      @map[key].each_with_index do |matcher, index|
        if specificity(new_matcher) >= specificity(matcher)
          if filters == matcher[:filters] && !!block == !!matcher[:block] && value != matcher[:value] && !override
            Chef::Log.warn "You are overriding #{key} #{filters.inspect} with #{value.inspect}: used to be #{matcher[:value].inspect}. Use override: true if this is what you intended."
          end
          insert_at = index
          break
        end
      end
      if insert_at
        @map[key].insert(insert_at, new_matcher)
      else
        @map[key] << new_matcher
      end
      self
    end

    #
    # Get a value from the NodeMap via applying the node to the filters that
    # were set on the key.
    #
    # @param node [Chef::Node] The Chef::Node object for the run, or `nil` to
    #   ignore all filters.
    # @param key [Object] Key to look up
    # @param canonical [Boolean] `true` or `false` to match canonical or
    #   non-canonical values only. `nil` to ignore canonicality.  Default: `nil`
    #
    # @return [Object] Value
    #
    def get(node, key, canonical: nil)
      raise ArgumentError, "first argument must be a Chef::Node" unless node.is_a?(Chef::Node) || node.nil?
      list(node, key, canonical: canonical).first
    end

    #
    # List all matches for the given node and key from the NodeMap, from
    # most-recently added to oldest.
    #
    # @param node [Chef::Node] The Chef::Node object for the run, or `nil` to
    #   ignore all filters.
    # @param key [Object] Key to look up
    # @param canonical [Boolean] `true` or `false` to match canonical or
    #   non-canonical values only. `nil` to ignore canonicality.  Default: `nil`
    #
    # @return [Object] Value
    #
    def list(node, key, canonical: nil)
      raise ArgumentError, "first argument must be a Chef::Node" unless node.is_a?(Chef::Node) || node.nil?
      return [] unless @map.has_key?(key)
      @map[key].select do |matcher|
        node_matches?(node, matcher) && canonical_matches?(canonical, matcher)
      end.map { |matcher| matcher[:value] }
    end

    # Seriously, don't use this, it's nearly certain to change on you
    # @return remaining
    # @api private
    def delete_canonical(key, value)
      remaining = @map[key]
      if remaining
        remaining.delete_if { |matcher| matcher[:canonical] && Array(matcher[:value]) == Array(value) }
        if remaining.empty?
          @map.delete(key)
          remaining = nil
        end
      end
      remaining
    end

    private

    #
    # Gives a value for "how specific" the matcher is.
    # Things which specify more specific filters get a higher number
    # (platform_version > platform > platform_family > os); things
    # with a block have higher specificity than similar things without
    # a block.
    #
    def specificity(matcher)
      if matcher[:filters][:platform_version]
        specificity = 8
      elsif matcher[:filters][:platform]
        specificity = 6
      elsif matcher[:filters][:platform_family]
        specificity = 4
      elsif matcher[:filters][:os]
        specificity = 2
      else
        specificity = 0
      end
      specificity += 1 if matcher[:block]
      specificity
    end

    #
    # Succeeds if:
    # - no negative matches (!value)
    # - at least one positive match (value or :all), or no positive filters
    #
    def matches_black_white_list?(node, filters, attribute)
      # It's super common for the filter to be nil.  Catch that so we don't
      # spend any time here.
      return true if !filters[attribute]
      filter_values = Array(filters[attribute])
      value = node[attribute]

      # Split the blacklist and whitelist
      blacklist, whitelist = filter_values.partition { |v| v.is_a?(String) && v.start_with?('!') }

      # If any blacklist value matches, we don't match
      return false if blacklist.any? { |v| v[1..-1] == value }

      # If the whitelist is empty, or anything matches, we match.
      whitelist.empty? || whitelist.any? { |v| v == :all || v == value }
    end

    def matches_version_list?(node, filters, attribute)
      # It's super common for the filter to be nil.  Catch that so we don't
      # spend any time here.
      return true if !filters[attribute]
      filter_values = Array(filters[attribute])
      value = node[attribute]

      filter_values.empty? ||
      Array(filter_values).any? do |v|
        Chef::VersionConstraint::Platform.new(v).include?(value)
      end
    end

    def filters_match?(node, filters)
      matches_black_white_list?(node, filters, :os) &&
      matches_black_white_list?(node, filters, :platform_family) &&
      matches_black_white_list?(node, filters, :platform) &&
      matches_version_list?(node, filters, :platform_version)
    end

    def block_matches?(node, block)
      return true if block.nil?
      block.call node
    end

    def node_matches?(node, matcher)
      return true if !node
      filters_match?(node, matcher[:filters]) && block_matches?(node, matcher[:block])
    end

    def canonical_matches?(canonical, matcher)
      return true if canonical.nil?
      !!canonical == !!matcher[:canonical]
    end
  end
end
