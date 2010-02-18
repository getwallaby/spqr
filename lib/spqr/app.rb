# SPQR:  Schema Processor for QMF/Ruby agents
#
# Application skeleton class
#
# Copyright (c) 2009 Red Hat, Inc.
#
# Author:  William Benton (willb@redhat.com)
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0

require 'spqr/spqr'
require 'qmf'
require 'logger'

module SPQR
  class App < Qmf::AgentHandler
    class ClassMeta < Struct.new(:object_class, :schema_class) ; end

    attr_reader :agent

    def initialize(options=nil)
      defaults = {:logfile=>STDERR, :loglevel=>Logger::WARN, :notifier=>nil, :server=>"localhost", :port=>5672}
      
      # convenient shorthands for log levels
      loglevels = {:debug => Logger::DEBUG, :info => Logger::INFO, :warn => Logger::WARN, :error => Logger::ERROR, :fatal => Logger::FATAL}
        
      options = defaults unless options

      # set unsupplied options to defaults
      defaults.each do |k,v|
        options[k] = v unless options[k]
      end

      # fix up shorthands
      options[:loglevel] = loglevels[options[:loglevel]] if loglevels[options[:loglevel]]

      @log = Logger.new(options[:logfile])
      @log.level = options[:loglevel]

      @log.info("initializing SPQR app....")

      @classes_by_name = {}
      @classes_by_id = {}
      @pipe = options[:notifier]
      @app_name = (options[:appname] or "SPQR application")
      @qmf_host = options[:server]
      @qmf_port = options[:port]
      @qmf_sendUserId = if options.has_key?(:send_user_id)
                          options[:send_user_id]
                        else
                          (options.has_key?(:user) or options.has_key?(:password))
                        end
      
      @qmf_user = options[:user]
      @qmf_password = options[:password]
    end

    def register(*ks)
      manageable_ks = ks.select {|kl| manageable? kl}
      unmanageable_ks = ks.select {|kl| not manageable? kl}
      manageable_ks.each do |klass|
        @log.info("SPQR will manage registered class #{klass} (#{klass.spqr_meta.classname})...")
        
        schemaclass = schematize(klass)

        klass.log = @log
        
        @log.debug("SETTING klass.app to #{self.inspect}")
        klass.app = self
        
        @classes_by_id[klass.class_id] = klass
        @classes_by_name[klass.spqr_meta.classname.to_s] = ClassMeta.new(klass, schemaclass)
      end
      
      unmanageable_ks.each do |klass|
        @log.warn("SPQR can't manage #{klass}, which was registered")
      end
    end


    def method_call(context, name, obj_id, args, user_id)
      begin
        class_id = obj_id.object_num_high
        obj_id = obj_id.object_num_low

        @log.debug "calling method: context=#{context} method=#{name} object_id=#{obj_id}, args=#{args}, user=#{user_id}"

        managed_object = find_object(context, class_id, obj_id)
        @log.debug("managed object is #{managed_object}")
        managed_method = managed_object.class.spqr_meta.mmethods[name.to_sym]

        raise RuntimeError.new("#{managed_object.class} does not have #{name} exposed as a manageable method; has #{managed_object.class.spqr_meta.mmethods.inspect}") unless managed_method

        # Extract actual parameters from the Qmf::Arguments structure into a proper ruby list
        @log.debug("actual params are: #{args.instance_variable_get(:@by_hash).inspect}") rescue nil
        actuals_in = managed_method.formals_in.inject([]) {|acc,nm| acc << args[nm]}
        actual_count = actuals_in.size

        @log.debug("managed_object.respond_to? #{managed_method.name.to_sym} ==> #{managed_object.respond_to? managed_method.name.to_sym}")
        @log.debug("managed_object.class.spqr_meta.mmethods.include? #{name.to_sym} ==> #{managed_object.class.spqr_meta.mmethods.include? name.to_sym}")
        @log.debug("formals:  #{managed_method.formals_in.inspect}")
        @log.debug("actuals:  #{actuals_in.inspect}")

        actuals_out = case actual_count
          when 0 then managed_object.send(name.to_sym)
          when 1 then managed_object.send(name.to_sym, actuals_in[0])
          else managed_object.send(name.to_sym, *actuals_in)
        end

        raise RuntimeError.new("#{managed_object.class} did not return the appropriate number of return values; got '#{actuals_out.inspect}', but expected #{managed_method.types_out.inspect}") unless result_valid(actuals_out, managed_method)
        
        if managed_method.formals_out.size == 0
          actuals_out = [] # ignore return value in this case
        elsif managed_method.formals_out.size == 1
          actuals_out = [actuals_out] # wrap this up in a list
        end
        
        @log.debug("formals_out == #{managed_method.formals_out.inspect}")
        @log.debug("actuals_out == #{actuals_out.inspect}")

        # Copy any out parameters from return value to the
        # Qmf::Arguments structure; see XXX above
        managed_method.formals_out.zip(actuals_out).each do |k,v|
          @log.debug("fixing up out params:  #{k.inspect} --> #{v.inspect}")
          encoded_val = encode_object(v)
          args[k] = encoded_val
        end

        @agent.method_response(context, 0, "OK", args)
      rescue Exception => ex
        @log.error "Error calling #{name}: #{ex}"
        @log.error "    " + ex.backtrace.join("\n    ")
        @agent.method_response(context, 1, "ERROR: #{ex}", args)
      end
    end

    def get_query(context, query, user_id)
      @log.debug "query: user=#{user_id} context=#{context} class=#{query.class_name} object_num=#{query.object_id.object_num_low if query.object_id} details=#{query} haveSelect=#{query.impl and query.impl.haveSelect} getSelect=#{query.impl and query.impl.getSelect} (#{query.impl and query.impl.getSelect and query.impl.getSelect.methods.inspect})"

      @log.debug "classes_by_name is #{@classes_by_name.inspect}"

      cmeta = @classes_by_name[query.class_name]
      objs = []
      
      # XXX:  are these cases mutually exclusive?
      
      # handle queries for a certain class
      if cmeta
        objs = objs + cmeta.object_class.find_all.collect {|obj| qmfify(obj)}
      end

      # handle queries for a specific object
      o = find_object(context, query.object_id.object_num_high, query.object_id.object_num_low) rescue nil
      if o
        objs << qmfify(o)
      end

      objs.each do |obj| 
        @log.debug("query_response of: #{obj.inspect}")
        @agent.query_response(context, obj) rescue @log.error($!.inspect)
      end
      
      @log.debug("completing query....")
      @agent.query_complete(context)
    end

    def main
      # XXX:  fix and parameterize as necessary
      @log.debug("starting SPQR::App.main...")
      
      settings = Qmf::ConnectionSettings.new
      settings.host = @qmf_host
      settings.port = @qmf_port
      settings.sendUserId = @qmf_sendUserId
      
      settings.username = @qmf_user if @qmf_sendUserId
      settings.password = @qmf_password if @qmf_sendUserId
      
      @connection = Qmf::Connection.new(settings)
      @log.debug(" +-- @connection created:  #{@connection}")
      @log.debug(" +-- app name is '#{@app_name}'")

      @agent = Qmf::Agent.new(self, @app_name)
      @log.debug(" +-- @agent created:  #{@agent}")

      @agent.set_connection(@connection)
      @log.debug(" +-- @agent.set_connection called")

      @log.debug(" +-- registering classes...")
      @classes_by_name.values.each do |km| 
        @agent.register_class(km.schema_class) 
        @log.debug(" +--+-- #{km.schema_class.package_name} #{km.schema_class.class_name} registered")
      end
      
      @log.debug("entering orbit....")

      sleep
    end

    private
    
    def result_valid(actuals, mm)
      (actuals.kind_of?(Array) and mm.formals_out.size == actuals.size) or mm.formals_out.size <= 1
    end
    
    def qmf_arguments_to_hash(args)
      result = {}
      args.each do |k,v|
        result[k] = v
      end
      result
    end

    def encode_object(o)
      return o unless o.kind_of? ::SPQR::Manageable
      @agent.alloc_object_id(*(o.qmf_id))
    end

    def find_object(ctx, c_id, obj_id)
      # XXX:  context is currently ignored
      @log.debug("in find_object; class ID is #{c_id}, object ID is #{obj_id}...")
      klass = @classes_by_id[c_id]
      @log.debug("found class #{klass.inspect}")
      klass.find_by_id(obj_id) if klass
    end
    
    def schematize(klass)
      @log.info("Making a QMF schema for #{klass.spqr_meta.classname}")

      meta = klass.spqr_meta
      package = meta.package.to_s
      classname = meta.classname.to_s
      @log.info("+-- class #{classname} is in package #{package}")

      sc = Qmf::SchemaObjectClass.new(package, classname)
      
      meta.manageable_methods.each do |mm|
        @log.info("+-- creating a QMF schema for method #{mm}")
        m_opts = mm.options
        m_opts[:desc] ||= mm.description if mm.description
        
        method = Qmf::SchemaMethod.new(mm.name.to_s, m_opts)
        
        mm.args.each do |arg| 
          @log.info("| +-- creating a QMF schema for arg #{arg}")
          
          arg_opts = arg.options
          arg_opts[:desc] ||= arg.description if (arg.description and arg.description.is_a? String)
          arg_opts[:dir] ||= get_xml_constant(arg.direction.to_s, ::SPQR::XmlConstants::Direction)
          arg_name = arg.name.to_s
          arg_type = get_xml_constant(arg.kind.to_s, ::SPQR::XmlConstants::Type)
          
          if @log.level <= Logger::DEBUG
            local_variables.grep(/^arg_/).each do |local|
              @log.debug("      #{local} --> #{(eval local).inspect}")
            end
          end

          method.add_argument(Qmf::SchemaArgument.new(arg_name, arg_type, arg_opts))
        end

        sc.add_method(method)
      end

      add_attributes(sc, meta.properties, :add_property, Qmf::SchemaProperty)
      add_attributes(sc, meta.statistics, :add_statistic, Qmf::SchemaStatistic)

      sc
    end
    
    def add_attributes(sc, collection, msg, klass, what=nil)
      what ||= (msg.to_s.split("_").pop rescue "property or statistic")
      collection.each do |basic|
        basic_name = basic.name.to_s
        basic_type = get_xml_constant(basic.kind.to_s, ::SPQR::XmlConstants::Type)
        @log.debug("+-- creating a QMF schema for #{what} #{basic_name} (#{basic_type}) with options #{basic.options.inspect}")
        sc.send(msg, klass.new(basic_name, basic_type, basic.options))
      end
    end

    def manageable?(k)
      # FIXME:  move out of App, into Manageable or a related utils module?
      k.is_a? Class and k.included_modules.include? ::SPQR::Manageable
    end

    def get_xml_constant(xml_key, dictionary)
      # FIXME:  move out of App, into a utils module?
      string_val = dictionary[xml_key]
      return xml_key unless string_val

      actual_val = const_lookup(string_val)
      return string_val unless actual_val

      return actual_val
    end

    # turns a string name of a constant into the value of that
    # constant; returns that value, or nil if fqcn doesn't correspond
    # to a valid constant
    def const_lookup(fqcn)
      # FIXME:  move out of App, into a utils module?
      hierarchy = fqcn.split("::")
      const = hierarchy.pop
      mod = Kernel
      hierarchy.each do |m|
        mod = mod.const_get(m)
      end
      mod.const_get(const) rescue nil
    end

    # turns an instance of a managed object into a QmfObject
    def qmfify(obj)
      @log.debug("trying to qmfify #{obj}:  qmf_oid is #{obj.qmf_oid} and class_id is #{obj.class.class_id}")
      cm = @classes_by_name[obj.class.spqr_meta.classname.to_s]
      return nil unless cm

      qmfobj = Qmf::AgentObject.new(cm.schema_class)

      set_attrs(qmfobj, obj)

      @log.debug("calling alloc_object_id(#{obj.qmf_oid}, #{obj.class.class_id})")
      oid = @agent.alloc_object_id(obj.qmf_oid, obj.class.class_id)
      
      @log.debug("calling qmfobj.set_object_id(#{oid})")
      qmfobj.set_object_id(oid)
      
      @log.debug("returning from qmfify")
      qmfobj
    end

    def set_attrs(qo, o)
      return unless o.class.respond_to? :spqr_meta
      
      attrs = o.class.spqr_meta.properties + o.class.spqr_meta.statistics

      attrs.each do |a|
        getter = a.name.to_s
        @log.debug("setting property/statistic #{getter} to its value from #{o}: #{o.send(getter) if o.respond_to?(getter)}")
        value = o.send(getter) if o.respond_to?(getter)
        if value
          # XXX: remove this line when/if Manageable includes an
          # appropriate impl method
          value = encode_object(value) if value.kind_of?(::SPQR::Manageable)
          qo[getter] = value
        end
      end
    end
  end
end
