require "spy/version"
require "spy/double"
require "spy/dsl"

class Spy
  CallLog = Struct.new(:object, :args, :block)

  attr_reader :base_object, :method_name, :calls
  def initialize(object, method_name)
    @base_object, @method_name = object, method_name
    reset!
  end

  def hook(opts = {})
    raise "#{method_name} method has already been hooked" if hooked?
    opts[:force] ||= base_object.kind_of?(Double)
    if method_visibility || !opts[:force]
      @original_method = base_object.method(method_name)
      if base_object.singleton_methods.include?(method_name)
        @removed_singleton_method = true
        base_object.singleton_class.send(:remove_method, method_name)
      end
    end

    __spies_spy = self
    base_object.define_singleton_method(method_name) do |*args, &block|
      __spies_spy.record(self,args,block)
    end

    opts[:visibility] ||= method_visibility
    base_object.singleton_class.send(opts[:visibility], method_name) if opts[:visibility]
    @hooked = true
    self
  end

  def unhook
    raise "#{method_name} method has not been hooked" unless hooked?
    base_object.singleton_class.send(:remove_method, method_name)
    base_object.define_singleton_method(method_name, original_method) if @removed_singleton_method
    base_object.singleton_class.send(method_visibility, method_name) if method_visibility
    clear_method!
    self
  end

  def hooked?
    @hooked
  end

  def and_return(value = nil, &block)
    if block_given?
      raise ArgumentError.new("value and block conflict. Choose one") if !value.nil?
      @plan = block
    else
      @plan = Proc.new { value }
    end
    self
  end

  def and_call_through
    raise "can only call through if original method is set" unless original_method
    @plan = original_method
  end

  def has_been_called?
    calls.size > 0
  end

  def has_been_called_with?(*args)
    calls.any? do |call_log|
      call_log.args == args
    end
  end

  def record(object, args, block)
    check_arity!(args.size)
    calls << CallLog.new(object, args, block)
    @plan.call(*args, &block) if @plan
  end

  def reset!
    @calls = []
    clear_method!
    true
  end

  private
  attr_reader :original_method

  def clear_method!
    @hooked = false
    @original_method = @arity_range = @method_visiblity = @removed_singleton_method = nil
  end

  def method_visibility
    @method_visibility ||=
      if base_object.respond_to? method_name
        if base_object.class.public_method_defined? method_name
          :public
        elsif base_object.class.protected_method_defined? method_name
          :protected
        end
      elsif base_object.class.private_method_defined? method_name
        :private
      end
  end

  def check_arity!(arity)
    return unless arity_range
    if arity < arity_range.min
      raise ArgumentError.new("wrong number of arguments (#{arity} for #{arity_range.min})")
    elsif arity > arity_range.max
      raise ArgumentError.new("wrong number of arguments (#{arity} for #{arity_range.max})")
    end
  end

  def arity_range
    @arity_range ||=
      if original_method
        min = max = 0
        original_method.parameters.each do |type,_|
          case type
          when :req
            min += 1
            max += 1
          when :opt
            max += 1
          when :rest
            max = Float::INFINITY
          end
        end
        (min..max)
      end
  end

  class << self
    def on(base_object, *method_names)
      spies = method_names.map do |method_name|
        create_and_hook_spy(base_object, method_name)
      end.flatten

      spies.one? ? spies.first : spies
    end

    def stub(base_object, *method_names)
      spies = method_names.map do |method_name|
        create_and_hook_spy(base_object, method_name, force: true)
      end.flatten

      spies.one? ? spies.first : spies
    end

    def off(base_object, *method_names)
      removed_spies = method_names.map do |method_name|
        unhook_and_remove_spy(base_object, method_name)
      end.flatten

      removed_spies.one? ? removed_spies.first : removed_spies
    end

    def all
      @all ||= []
    end

    def teardown
      all.each(&:unhook)
      reset
    end

    def reset
      @all = nil
    end

    def double(*args)
      Double.new(*args)
    end

    def find(base_object, *method_names)
      method_names = method_names.map do |method_name|
        case method_name
        when String, Symbol
          method_name
        when Hash
          method_name.keys
        end
      end.flatten

      @all[base_object.object_id].values_at(*method_names)
    end

    private

    def create_and_hook_spy(base_object, method_name, opts = {})
      case method_name
      when String, Symbol
        spy = new(base_object, method_name).hook(opts)
        all << spy
        spy
      when Hash
        method_name.map do |name, result|
          create_and_hook_spy(base_object, name, opts).and_return(result)
        end
      else
        raise ArgumentError.new "#{method_name.class} is an invalid class, #on only accepts String, Symbol, and Hash"
      end
    end

    def unhook_and_remove_spy(base_object, method_name)
      removed_spies = []
      all.delete_if do |spy|
        if spy.base_object == base_object && spy.method_name == method_name
          removed_spies << spy.unhook
        end
      end
      removed_spies
    end
  end
end