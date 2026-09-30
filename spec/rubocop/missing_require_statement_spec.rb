# frozen_string_literal: true

RSpec.describe RuboCop::Cop::Require::MissingRequireStatement do
  subject(:cop) { described_class.new(config) }

  let(:config) { RuboCop::Config.new }

  describe 'require' do
    it 'registers an offense when missing' do
      expect_offense(<<~RUBY)
        WeakRef.new(["test"])
        ^^^^^^^ Require/MissingRequireStatement: `WeakRef` not found, you're probably missing a require statement or there is a cycle in your dependencies.
      RUBY
    end

    it 'does not register an offense when present' do
      expect_no_offenses(<<~RUBY)
        require 'weakref'
        WeakRef.new([ "test" ])
      RUBY
    end

    it 'registers an offense when too late' do
      expect_offense(<<~RUBY)
        WeakRef.new(["test"])
        ^^^^^^^ Require/MissingRequireStatement: `WeakRef` not found, you're probably missing a require statement or there is a cycle in your dependencies.
        require 'weakref'
      RUBY
    end
  end

  describe 'modules/classes defined in file' do
    it 'does not register offenses for earlier definitions' do
      expect_no_offenses(<<~RUBY)
        module A
          module B
            class C
              def test
              end
            end
          end
        end
        A::B::C.new.test
      RUBY
    end

    it 'does not register an offense for later definitions' do
      # In a case where the `B::C.new.test` call would be top-level instead of in a method, ruby
      # would give a NameError, so it is a good approximation not to complain about a missing require 
      # in this case: There is no missing require - the order has to be changed to fix this instead
      expect_no_offenses(<<~RUBY)
        def test
          B::C.new.test
        end
        module B
          class C
            def test; end
          end
        end
      RUBY
    end
  end

  describe 'actual constants' do
    it 'does not register offenses for earlier definitions' do
      expect_no_offenses(<<~RUBY)
        MY_VERSION = 5
        MY_VERSION.to_i
      RUBY
    end

    it 'does not register offenses for later definitions' do
      # Ruby will NameError here as well
      expect_no_offenses(<<~RUBY)
        MY_VERSION.to_i
        MY_VERSION = 5
      RUBY
    end
  end

  describe 'aliased constants' do
    it 'does not register an offense when accessing the alias itself' do
      expect_no_offenses(<<~RUBY)
        require 'net/http'
        MyHTTP = Net::HTTP
        MyHTTP.new('example.com')
      RUBY
    end

    it 'does not register an offense for member access through an alias' do
      # `MyHTTP` is an alias for the real, loaded `Net::HTTP`, so `MyHTTP::Get`
      # resolves to `Net::HTTP::Get` and should not be flagged.
      expect_no_offenses(<<~RUBY)
        require 'net/http'
        MyHTTP = Net::HTTP
        MyHTTP::Get.new('/')
      RUBY
    end

    it 'resolves an alias that is itself a nested constant' do
      # Mirrors the reported fastlane case: a shorthand alias for a deeply nested,
      # already-required constant, then member access through that alias.
      expect_no_offenses(<<~RUBY)
        require 'net/http'
        module Foo
          HTTP = Net::HTTP
          def self.get
            HTTP::Get.new('/')
          end
        end
      RUBY
    end

    it 'still registers an offense for member access of an unknown constant' do
      expect_offense(<<~RUBY)
        MyHTTP::Get.new('/')
        ^^^^^^^^^^^ Require/MissingRequireStatement: `MyHTTP::Get` not found, you're probably missing a require statement or there is a cycle in your dependencies.
      RUBY
    end
  end

  describe 'inheritance' do
    it 'registers an offense when not available' do
      expect_offense(<<~RUBY)
      class A < B
      ^^^^^^^^^^^ Require/MissingRequireStatement: `B` not found, you're probably missing a require statement or there is a cycle in your dependencies.
      end
      RUBY
    end

    it 'does not register an offense when defined in the same file' do
      expect_no_offenses(<<~RUBY)
        module B
          class C; end
        end
        class A < B::C; end
      RUBY
    end

    it 'does not register an offense for required files' do
      expect_no_offenses(<<~RUBY)
        require 'weakref'
        class A < WeakRef; end
      RUBY
    end
  end

  describe 'constants guarded by a check that they are defined' do
    it 'does not register an offense inside `if Object.const_defined?`' do
      expect_no_offenses(<<~RUBY)
        if Object.const_defined?("Optional")
          Optional.call
        end
      RUBY
    end

    it 'registers an offense for a constant nested in the checked one' do
      # Optional can be defined while Optional::Helper is not loaded yet
      expect_offense(<<~RUBY)
        if Object.const_defined?("Optional")
          Optional::Helper.call
          ^^^^^^^^^^^^^^^^ Require/MissingRequireStatement: `Optional::Helper` not found, you're probably missing a require statement or there is a cycle in your dependencies.
        end
      RUBY
    end

    it 'does not register an offense inside a chain of const_defined? checks' do
      expect_no_offenses(<<~RUBY)
        if Object.const_defined?("Optional") && Optional.const_defined?("UI")
          Optional::UI.interactive?
        end
      RUBY
    end

    it 'does not register an offense inside `if defined?`' do
      expect_no_offenses(<<~RUBY)
        Optional.call if defined?(Optional)
      RUBY
    end

    it 'registers an offense in the branch where the constant is not defined' do
      expect_offense(<<~RUBY)
        if Object.const_defined?("Optional")
          true
        else
          Optional.call
          ^^^^^^^^ Require/MissingRequireStatement: `Optional` not found, you're probably missing a require statement or there is a cycle in your dependencies.
        end
      RUBY
    end

    it 'registers an offense for a constant the check does not cover' do
      expect_offense(<<~RUBY)
        if Object.const_defined?("Optional")
          Other.call
          ^^^^^ Require/MissingRequireStatement: `Other` not found, you're probably missing a require statement or there is a cycle in your dependencies.
        end
      RUBY
    end

    it 'registers an offense when either check may be false' do
      expect_offense(<<~RUBY)
        if Object.const_defined?("Optional") || ready?
          Optional.call
          ^^^^^^^^ Require/MissingRequireStatement: `Optional` not found, you're probably missing a require statement or there is a cycle in your dependencies.
        end
      RUBY
    end
  end
end
