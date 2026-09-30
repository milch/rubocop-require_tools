# frozen_string_literal: true

require 'rubocop'
require_relative '../../helper/state'

module RuboCop
  module Cop
    module Require
      # Checks for missing require statements in your code
      #
      # @example
      #   # bad
      #   Faraday.new
      #
      #   # good
      #   require 'faraday'
      #
      #   Faraday.new
      class MissingRequireStatement < Base
        MSG = '`%<constant>s` not found, you\'re probably missing a require statement or there is a cycle in your dependencies.'.freeze

        attr_writer :timeline

        def timeline
          @timeline ||= []
        end

        # Builds
        def on_new_investigation
          processing_methods = self.methods.select { |m| m.to_s.start_with? 'process_' }

          stack = [processed_source.ast]
          skip = Set.new
          until stack.empty?
            node = stack.pop
            next unless node

            results = processing_methods.map { |m| self.send(m, node, processed_source) }.compact

            next if node.kind_of? Hash

            to_skip, to_push = %i[skip push].map { |mode| results.flat_map { |r| r[mode] }.compact }

            skip.merge(to_skip)

            children_to_explore = node.children
                                      .select { |c| c.kind_of? RuboCop::AST::Node }
                                      .reject { |c| skip.include? c }
                                      .reverse
            stack.push(*to_push)
            stack.push(*children_to_explore)
          end

          err_events = check_timeline(timeline).group_by { |e| e[:name] }.values
          err_events.each do |events|
            first = events.first
            node = first[:node]
            message = format(
              MSG,
              constant: first[:name]
            )
            add_offense(node, message: message)
          end
        end

        def_node_matcher :extract_inner_const, <<-PATTERN
          (const $!nil? _)
        PATTERN

        def_node_matcher :extract_const, <<-PATTERN
          (const _ $_)
        PATTERN

        def find_consts(node)
          inner = node
          outer_const = extract_const(node)
          return unless outer_const
          consts = [outer_const]
          while (inner = extract_inner_const(inner))
            const = extract_const(inner)
            consts << const
          end
          consts.reverse
        end

        def process_const(node, _source)
          return unless node.kind_of? RuboCop::AST::Node
          consts = find_consts(node)
          return unless consts
          const_name = consts.join('::')

          self.timeline << { event: :const_access, name: const_name, node: node } unless guarded?(node, const_name)

          { skip: node.children }
        end

        def_node_matcher :const_defined_check, <<-PATTERN
          (send $_ :const_defined? ({str sym} $_) ...)
        PATTERN

        # True where a check that this very constant is defined has just passed: in the true branch of
        # an `if`, or on the right of an `&&`. Code that tests for an optional dependency is not missing a
        # require. A check on Foo does not cover Foo::Bar, which may still not be loaded.
        def guarded?(node, const_name)
          child = node
          node.each_ancestor do |ancestor|
            return true if ancestor.type == :defined? # defined?(Foo) is itself the check, and never raises

            condition = ancestor.children[0] if (ancestor.if_type? || ancestor.and_type?) && child.equal?(ancestor.children[1])
            return true if condition && checked_constants(condition).include?(const_name)

            child = ancestor
          end
          false
        end

        def checked_constants(condition)
          return condition.children.flat_map { |c| checked_constants(c) } if condition.and_type?

          if (checked = const_defined_check(condition))
            receiver, name = checked
            return [] unless receiver&.const_type?

            path = find_consts(receiver).join('::')
            return [path == 'Object' ? name.to_s : "#{path}::#{name}"]
          end

          # `defined?` cannot be written as a node pattern: the pattern language reads it as a predicate
          checked = condition.children.first if condition.type == :defined?
          checked&.const_type? ? [find_consts(checked).join('::')] : []
        end

        def_node_matcher :extract_const_assignment, <<-PATTERN
          (casgn nil? $_ ...)
        PATTERN

        def process_const_assign(node, _source)
          return unless node.kind_of? RuboCop::AST::Node
          const_assign_name = extract_const_assignment(node)
          return unless const_assign_name

          # When the assigned value is itself a constant reference, the assignment is an
          # alias (e.g. `Foo = Bar::Baz`). Track the target so member access through the
          # alias (`Foo::QUX`) can be resolved to the real constant later.
          value_node = node.children[2]
          alias_target = nil
          if value_node.kind_of?(RuboCop::AST::Node) && value_node.type == :const
            consts = find_consts(value_node)
            alias_target = consts.join('::') if consts
          end

          self.timeline << { event: :const_assign, name: const_assign_name, alias_target: alias_target }

          { skip: node.children }
        end

        def_node_matcher :is_module_or_class?, <<-PATTERN
          ({module class} ...)
        PATTERN

        def_node_matcher :has_superclass?, <<-PATTERN
          (class (const ...) (const ...) ...)
        PATTERN

        def process_definition(node, _source)
          if node.kind_of? Hash
            self.timeline << node
            return
          end

          return unless is_module_or_class?(node)
          name = find_consts(node.children.first).join('::')
          inherited = find_consts(node.children[1]).join('::') if has_superclass?(node)

          # Inheritance technically has to happen before the actual class definition
          self.timeline << { event: :const_inherit, name: inherited, node: node } if inherited

          self.timeline << { event: :const_def, name: name }

          # First child is the module/class name => skip or it'll be picked up by `process_const`
          skip_list = [node.children.first]
          skip_list << node.children[1] if inherited

          push_list = []
          push_list << { event: :const_undef, name: name }

          { skip: skip_list, push: push_list }
        end

        def_node_matcher :extract_include, <<-PATTERN
          (send nil? :include $(const ...))
        PATTERN

        # `include Foo` makes Foo's constants reachable unqualified in the enclosing class or module.
        def process_include(node, _source)
          return unless node.kind_of? RuboCop::AST::Node
          included = extract_include(node)
          return unless included

          self.timeline << { event: :include, name: find_consts(included).join('::') }
          nil
        end

        def_node_matcher :extract_require, <<-PATTERN
          (send nil? ${:require :require_relative} (str $_))
        PATTERN

        def process_require(node, source)
          return unless node.kind_of? RuboCop::AST::Node
          required = extract_require(node)
          return unless required && required.length == 2
          method, file = required
          self.timeline << { event: method, file: file, path: source.path }

          { skip: node.children }
        end

        private

        # Returns the problematic events from the timeline, i.e. those for which a require might be missing
        def check_timeline(timeline)
          return [] unless Process.respond_to?(:fork)

          # To avoid having to marshal/unmarshal the nodes, the fork will just return indices with an error
          err_indices = perform_in_fork do
            state = RuboCop::RequireTools::State.new
            err_indices = []
            timeline.each_with_index do |event, i|
              case event[:event]
              when :require
                state.require(file: event[:file])
              when :require_relative
                path_to_investigated_file = event[:path]
                relative_path = File.expand_path(File.join(File.dirname(path_to_investigated_file), event[:file]))
                state.require_relative(relative_path: relative_path)
              when :const_access
                err_indices << i unless state.access_const(const_name: event[:name])
              when :const_def
                state.define_const(const_name: event[:name])

                outdated = outdated_errors(err_indices.map { |e| timeline[e] }, state)
                err_indices = err_indices.reject { |e| outdated.include?(timeline[e]) }
              when :const_undef
                state.undefine_const(const_name: event[:name])
              when :include
                state.include_module(name: event[:name])
              when :const_assign
                state.const_assigned(const_name: event[:name], alias_target: event[:alias_target])

                previous_errors = err_indices.map { |e| timeline[e] }
                outdated = outdated_errors(previous_errors, state)
                err_indices = err_indices.reject { |e| outdated.include?(timeline[e]) }
              when :const_inherit
                success = state.access_const(const_name: event[:name])
                if success
                  state.define_const(const_name: event[:name], is_part_of_stack: false)
                else
                  err_indices << i
                end
              end
            end
            err_indices
          end

          err_indices.map { |i| timeline[i] }
        end

        def outdated_errors(error_events, state)
          error_events
            .select { |e| %i[const_access const_inherit].include? e[:event] } # Only these types can be resolved by definitions later in the file
            .select { |e| state.access_const(const_name: e[:name], local_only: true) }
        end

        def perform_in_fork
          r, w = IO.pipe

          # The close statements are as they are used in the IO#pipe documentation
          pid = Process.fork do
            r.close
            result = yield
            Marshal.dump(result, w)
            w.close
          end

          w.close
          result = Marshal.load(r)
          r.close
          _, status = Process.waitpid2(pid)

          raise 'An error occured while forking' unless status.to_i.zero?

          return result
        end
      end
    end
  end
end
