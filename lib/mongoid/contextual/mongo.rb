# frozen_string_literal: true

require "mongoid/contextual/atomic"
require "mongoid/contextual/aggregable/mongo"
require "mongoid/contextual/command"
require "mongoid/contextual/geo_near"
require "mongoid/contextual/map_reduce"
require "mongoid/association/eager_loadable"

module Mongoid
  module Contextual
    class Mongo
      extend Forwardable
      include Enumerable
      include Aggregable::Mongo
      include Atomic
      include Association::EagerLoadable
      include Queryable

      Mongoid.deprecate(self, :geo_near)

      # Options constant.
      OPTIONS = [ :hint,
                  :limit,
                  :skip,
                  :sort,
                  :batch_size,
                  :max_scan,
                  :max_time_ms,
                  :snapshot,
                  :comment,
                  :read,
                  :cursor_type,
                  :collation
                ].freeze

      # @attribute [r] view The Mongo collection view.
      attr_reader :view

      # Is the context cached?
      #
      # @example Is the context cached?
      #   context.cached?
      #
      # @return [ true, false ] If the context is cached.
      def cached?
        !!@cache
      end

      # Get the number of documents matching the query.
      #
      # @example Get the number of matching documents.
      #   context.count
      #
      # @example Get the count of documents with the provided options.
      #   context.count(limit: 1)
      #
      # @example Get the count for where the provided block is true.
      #   context.count do |doc|
      #     doc.likes > 1
      #   end
      #
      # @param [ Hash ] options The options, such as skip and limit to be factored
      #   into the count.
      #
      # @return [ Integer ] The number of matches.
      def count(options = {}, &block)
        return super(&block) if block_given?
        try_cache(:count) { view.count_documents(options) }
      end

      # Get the estimated number of documents matching the query.
      #
      # Unlike count, estimated_count does not take a block because it is not
      # traditionally defined (with a block) on Enumarable like count is.
      #
      # @example Get the estimated number of matching documents.
      #   context.estimated_count
      #
      # @param [ Hash ] options The options, such as maxTimeMS to be factored
      #   into the count.
      #
      # @return [ Integer ] The number of matches.
      def estimated_count(options = {})
        unless self.criteria.selector.empty?
          raise Mongoid::Errors::InvalidEstimatedCountCriteria.new(self.klass)
        end
        try_cache(:estimated_count) { view.estimated_document_count(options) }
      end

      # Delete all documents in the database that match the selector.
      #
      # @example Delete all the documents.
      #   context.delete
      #
      # @return [ nil ] Nil.
      def delete
        view.delete_many.deleted_count
      end
      alias :delete_all :delete

      # Destroy all documents in the database that match the selector.
      #
      # @example Destroy all the documents.
      #   context.destroy
      #
      # @return [ nil ] Nil.
      def destroy
        each.inject(0) do |count, doc|
          doc.destroy
          count += 1 if acknowledged_write?
          count
        end
      end
      alias :destroy_all :destroy

      # Get the distinct values in the db for the provided field.
      #
      # @example Get the distinct values.
      #   context.distinct(:name)
      #
      # @param [ String, Symbol ] field The name of the field.
      #
      # @return [ Array<Object> ] The distinct values for the field.
      def distinct(field)
        name = if Mongoid.legacy_pluck_distinct
          klass.database_field_name(field)
        else
          klass.cleanse_localized_field_names(field)
        end

        view.distinct(name).map do |value|
          if Mongoid.legacy_pluck_distinct
            value.class.demongoize(value)
          else
            is_translation = "#{name}_translations" == field.to_s
            recursive_demongoize(name, value, is_translation)
          end
        end
      end

      # Iterate over the context. If provided a block, yield to a Mongoid
      # document for each, otherwise return an enum.
      #
      # @example Iterate over the context.
      #   context.each do |doc|
      #     puts doc.name
      #   end
      #
      # @return [ Enumerator ] The enumerator.
      def each(&block)
        if block_given?
          documents_for_iteration.each do |doc|
            yield_document(doc, &block)
          end
          @cache_loaded = true
          self
        else
          to_enum
        end
      end

      # Do any documents exist for the context.
      #
      # @example Do any documents exist for the context.
      #   context.exists?
      #
      # @note We don't use count here since Mongo does not use counted
      #   b-tree indexes, unless a count is already cached then that is
      #   used to determine the value.
      #
      # @return [ true, false ] If the count is more than zero.
      def exists?
        return !documents.empty? if cached? && cache_loaded?
        return @count > 0 if instance_variable_defined?(:@count)

        try_cache(:exists) do
          !!(view.projection(_id: 1).limit(1).first)
        end
      end

      # Run an explain on the criteria.
      #
      # @example Explain the criteria.
      #   Band.where(name: "Depeche Mode").explain
      #
      # @return [ Hash ] The explain result.
      def explain
        view.explain
      end

      # Execute the find and modify command, used for MongoDB's
      # $findAndModify.
      #
      # @example Execute the command.
      #   context.find_one_and_update({ "$inc" => { likes: 1 }})
      #
      # @param [ Hash ] update The updates.
      # @param [ Hash ] options The command options.
      #
      # @option options [ :before, :after ] :return_document Return the updated document
      #   from before or after update.
      # @option options [ true, false ] :upsert Create the document if it doesn't exist.
      #
      # @return [ Document ] The result of the command.
      def find_one_and_update(update, options = {})
        if doc = view.find_one_and_update(update, options)
          Factory.from_db(klass, doc)
        end
      end

      # Execute the find and modify command, used for MongoDB's
      # $findAndModify.
      #
      # @example Execute the command.
      #   context.find_one_and_update({ likes: 1 })
      #
      # @param [ Hash ] replacement The replacement.
      # @param [ Hash ] options The command options.
      #
      # @option options [ :before, :after ] :return_document Return the updated document
      #   from before or after update.
      # @option options [ true, false ] :upsert Create the document if it doesn't exist.
      #
      # @return [ Document ] The result of the command.
      def find_one_and_replace(replacement, options = {})
        if doc = view.find_one_and_replace(replacement, options)
          Factory.from_db(klass, doc)
        end
      end

      # Execute the find and modify command, used for MongoDB's
      # $findAndModify. This deletes the found document.
      #
      # @example Execute the command.
      #   context.find_one_and_delete
      #
      # @return [ Document ] The result of the command.
      def find_one_and_delete
        if doc = view.find_one_and_delete
          Factory.from_db(klass, doc)
        end
      end

      # Get the first document in the database for the criteria's selector.
      #
      # @example Get the first document.
      #   context.first
      #
      # @note Automatically adding a sort on _id when no other sort is
      #   defined on the criteria has the potential to cause bad performance issues.
      #   If you experience unexpected poor performance when using #first or #last
      #   and have no sort defined on the criteria, use the option { id_sort: :none }.
      #   Be aware that #first/#last won't guarantee order in this case.
      #
      # @param [ Hash ] opts The options for the query returning the first document.
      #
      # @option opts [ :none ] :id_sort Don't apply a sort on _id if no other sort
      #   is defined on the criteria.
      #
      # @return [ Document ] The first document.
      def first(opts = {})
        return documents.first if cached? && cache_loaded?
        try_cache(:first) do
          if sort = view.sort || ({ _id: 1 } unless opts[:id_sort] == :none)
            if raw_doc = view.sort(sort).limit(1).first
              doc = Factory.from_db(klass, raw_doc, criteria)
              eager_load([doc]).first
            end
          else
            if raw_doc = view.limit(1).first
              doc = Factory.from_db(klass, raw_doc, criteria)
              eager_load([doc]).first
            end
          end
        end
      end
      alias :one :first

      # Return the first result without applying sort
      #
      # @api private
      def find_first
        return documents.first if cached? && cache_loaded?
        if raw_doc = view.first
          doc = Factory.from_db(klass, raw_doc, criteria)
          eager_load([doc]).first
        end
      end

      # Execute a $geoNear command against the database.
      #
      # @example Find documents close to 10, 10.
      #   context.geo_near([ 10, 10 ])
      #
      # @example Find with spherical distance.
      #   context.geo_near([ 10, 10 ]).spherical
      #
      # @example Find with a max distance.
      #   context.geo_near([ 10, 10 ]).max_distance(0.5)
      #
      # @example Provide a distance multiplier.
      #   context.geo_near([ 10, 10 ]).distance_multiplier(1133)
      #
      # @param [ Array<Float> ] coordinates The coordinates.
      #
      # @return [ GeoNear ] The GeoNear command.
      #
      # @deprecated
      def geo_near(coordinates)
        GeoNear.new(collection, criteria, coordinates)
      end

      # Invoke the block for each element of Contextual. Create a new array
      # containing the values returned by the block.
      #
      # If the symbol field name is passed instead of the block, additional
      # optimizations would be used.
      #
      # @example Map by some field.
      #   context.map(:field1)
      #
      # @example Map with block.
      #   context.map(&:field1)
      #
      # @param [ Symbol ] field The field name.
      #
      # @return [ Array ] The result of mapping.
      def map(field = nil, &block)
        if block_given?
          super(&block)
        else
          criteria.pluck(field)
        end
      end

      # Create the new Mongo context. This delegates operations to the
      # underlying driver.
      #
      # @example Create the new context.
      #   Mongo.new(criteria)
      #
      # @param [ Criteria ] criteria The criteria.
      def initialize(criteria)
        @criteria, @klass, @cache = criteria, criteria.klass, criteria.options[:cache]
        @collection = @klass.collection
        criteria.send(:merge_type_selection)
        @view = collection.find(criteria.selector, session: _session)
        apply_options
      end

      def_delegator :@klass, :database_field_name

      # Get the last document in the database for the criteria's selector.
      #
      # @example Get the last document.
      #   context.last
      #
      # @note Automatically adding a sort on _id when no other sort is
      #   defined on the criteria has the potential to cause bad performance issues.
      #   If you experience unexpected poor performance when using #first or #last
      #   and have no sort defined on the criteria, use the option { id_sort: :none }.
      #   Be aware that #first/#last won't guarantee order in this case.
      #
      # @param [ Hash ] opts The options for the query returning the first document.
      #
      # @option opts [ :none ] :id_sort Don't apply a sort on _id if no other sort
      #   is defined on the criteria.
      def last(opts = {})
        try_cache(:last) do
          with_inverse_sorting(opts) do
            if raw_doc = view.limit(1).first
              doc = Factory.from_db(klass, raw_doc, criteria)
              eager_load([doc]).first
            end
          end
        end
      end

      # Get's the number of documents matching the query selector.
      #
      # @example Get the length.
      #   context.length
      #
      # @return [ Integer ] The number of documents.
      def length
        @length ||= self.count
      end
      alias :size :length

      # Limits the number of documents that are returned from the database.
      #
      # @example Limit the documents.
      #   context.limit(20)
      #
      # @param [ Integer ] value The number of documents to return.
      #
      # @return [ Mongo ] The context.
      def limit(value)
        @view = view.limit(value) and self
      end

      # Initiate a map/reduce operation from the context.
      #
      # @example Initiate a map/reduce.
      #   context.map_reduce(map, reduce)
      #
      # @param [ String ] map The map js function.
      # @param [ String ] reduce The reduce js function.
      #
      # @return [ MapReduce ] The map/reduce lazy wrapper.
      def map_reduce(map, reduce)
        MapReduce.new(collection, criteria, map, reduce)
      end

      # Pluck the single field values from the database. Will return duplicates
      # if they exist and only works for top level fields.
      #
      # @example Pluck a field.
      #   context.pluck(:_id)
      #
      # @note This method will return the raw db values - it performs no custom
      #   serialization.
      #
      # @param [ String, Symbol, Array ] fields Fields to pluck.
      #
      # @return [ Array<Object, Array> ] The plucked values.
      def pluck(*fields)
        # Multiple fields can map to the same field name. For example, plucking
        # a field and its _translations field map to the same field in the database.
        # because of this, we need to keep track of the fields requested.
        normalized_field_names = []
        normalized_select = fields.inject({}) do |hash, f|
          db_fn = klass.database_field_name(f)
          normalized_field_names.push(db_fn)

          if Mongoid.legacy_pluck_distinct
            hash[db_fn] = true
          else
            hash[klass.cleanse_localized_field_names(f)] = true
          end
          hash
        end

        view.projection(normalized_select).reduce([]) do |plucked, doc|
          values = normalized_field_names.map do |n|
            if Mongoid.legacy_pluck_distinct
              n.include?('.') ? doc[n.partition('.')[0]] : doc[n]
            else
              extract_value(doc, n)
            end
          end
          plucked << (values.size == 1 ? values.first : values)
        end
      end

      # Skips the provided number of documents.
      #
      # @example Skip the documents.
      #   context.skip(20)
      #
      # @param [ Integer ] value The number of documents to skip.
      #
      # @return [ Mongo ] The context.
      def skip(value)
        @view = view.skip(value) and self
      end

      # Sorts the documents by the provided spec.
      #
      # @example Sort the documents.
      #   context.sort(name: -1, title: 1)
      #
      # @param [ Hash ] values The sorting values as field/direction(1/-1)
      #   pairs.
      #
      # @return [ Mongo ] The context.
      def sort(values = nil, &block)
        if block_given?
          super(&block)
        else
          # update the criteria
          @criteria = criteria.order_by(values)
          apply_option(:sort)
          self
        end
      end

      # Update the first matching document atomically.
      #
      # @example Update the first matching document.
      #   context.update({ "$set" => { name: "Smiths" }})
      #
      # @param [ Hash ] attributes The new attributes for the document.
      # @param [ Hash ] opts The update operation options.
      #
      # @option opts [ Array ] :array_filters A set of filters specifying to which array elements
      #   an update should apply.
      #
      # @return [ nil, false ] False if no attributes were provided.
      def update(attributes = nil, opts = {})
        update_documents(attributes, :update_one, opts)
      end

      # Update all the matching documents atomically.
      #
      # @example Update all the matching documents.
      #   context.update_all({ "$set" => { name: "Smiths" }})
      #
      # @param [ Hash ] attributes The new attributes for each document.
      # @param [ Hash ] opts The update operation options.
      #
      # @option opts [ Array ] :array_filters A set of filters specifying to which array elements
      #   an update should apply.
      #
      # @return [ nil, false ] False if no attributes were provided.
      def update_all(attributes = nil, opts = {})
        update_documents(attributes, :update_many, opts)
      end

      private

      # yield the block given or return the cached value
      #
      # @param [ String, Symbol ] key The instance variable name
      #
      # @return the result of the block
      def try_cache(key, &block)
        unless cached?
          yield
        else
          unless ret = instance_variable_get("@#{key}")
            instance_variable_set("@#{key}", ret = yield)
          end
          ret
        end
      end

      # Update the documents for the provided method.
      #
      # @api private
      #
      # @example Update the documents.
      #   context.update_documents(attrs)
      #
      # @param [ Hash ] attributes The updates.
      # @param [ Symbol ] method The method to use.
      #
      # @return [ true, false ] If the update succeeded.
      def update_documents(attributes, method = :update_one, opts = {})
        return false unless attributes
        attributes = Hash[attributes.map { |k, v| [klass.database_field_name(k.to_s), v] }]
        view.send(method, attributes.__consolidate__(klass), opts)
      end

      # Apply the field limitations.
      #
      # @api private
      #
      # @example Apply the field limitations.
      #   context.apply_fields
      def apply_fields
        if spec = criteria.options[:fields]
          @view = view.projection(spec)
        end
      end

      # Apply the options.
      #
      # @api private
      #
      # @example Apply all options.
      #   context.apply_options
      def apply_options
        apply_fields
        OPTIONS.each do |name|
          apply_option(name)
        end
        if criteria.options[:timeout] == false
          @view = view.no_cursor_timeout
        end
      end

      # Apply an option.
      #
      # @api private
      #
      # @example Apply the skip option.
      #   context.apply_option(:skip)
      def apply_option(name)
        if spec = criteria.options[name]
          @view = view.send(name, spec)
        end
      end

      # Map the inverse sort symbols to the correct MongoDB values.
      #
      # @api private
      #
      # @example Apply the inverse sorting params to the given block
      #   context.with_inverse_sorting
      def with_inverse_sorting(opts = {})
        begin
          if sort = criteria.options[:sort] || ( { _id: 1 } unless opts[:id_sort] == :none )
            @view = view.sort(Hash[sort.map{|k, v| [k, -1*v]}])
          end
          yield
        ensure
          apply_option(:sort)
        end
      end

      # Is the cache able to be added to?
      #
      # @api private
      #
      # @example Is the context cacheable?
      #   context.cacheable?
      #
      # @return [ true, false ] If caching, and the cache isn't loaded.
      def cacheable?
        cached? && !cache_loaded?
      end

      # Is the cache fully loaded? Will be true if caching after one full
      # iteration.
      #
      # @api private
      #
      # @example Is the cache loaded?
      #   context.cache_loaded?
      #
      # @return [ true, false ] If the cache is loaded.
      def cache_loaded?
        !!@cache_loaded
      end

      # Get the documents for cached queries.
      #
      # @api private
      #
      # @example Get the cached documents.
      #   context.documents
      #
      # @return [ Array<Document> ] The documents.
      def documents
        @documents ||= []
      end

      # Get the documents the context should iterate. This follows 3 rules:
      #
      # 1. If the query is cached, and we already have documents loaded, use
      #   them.
      # 2. If we are eager loading, then eager load the documents and use
      #   those.
      # 3. Use the query.
      #
      # @api private
      #
      # @example Get the documents for iteration.
      #   context.documents_for_iteration
      #
      # @return [ Array<Document>, Mongo::Collection::View ] The docs to iterate.
      def documents_for_iteration
        return documents if cached? && !documents.empty?
        return view unless eager_loadable?
        docs = view.map{ |doc| Factory.from_db(klass, doc, criteria) }
        eager_load(docs)
      end

      # Yield to the document.
      #
      # @api private
      #
      # @example Yield the document.
      #   context.yield_document(doc) do |doc|
      #     ...
      #   end
      #
      # @param [ Document ] document The document to yield to.
      def yield_document(document, &block)
        doc = document.respond_to?(:_id) ?
            document : Factory.from_db(klass, document, criteria)
        yield(doc)
        documents.push(doc) if cacheable?
      end

      private

      def _session
        @criteria.send(:_session)
      end

      def acknowledged_write?
        collection.write_concern.nil? || collection.write_concern.acknowledged?
      end

      # Extracts the value for the given field name from the given attribute
      # hash.
      #
      # @param [ Hash ] attrs The attributes hash.
      # @param [ String ] field_name The name of the field to extract.
      #
      # @param [ Object ] The value for the given field name
      def extract_value(attrs, field_name)
        def fetch_and_demongoize(d, meth, klass)
          res = d.try(:fetch, meth, nil)
          if field = klass.fields[meth]
            field.demongoize(res)
          else
            res.class.demongoize(res)
          end
        end

        i = 1
        num_meths = field_name.count('.') + 1
        k = klass
        curr = attrs.dup

        klass.traverse_association_tree(field_name) do |meth, obj, is_field|
          is_translation = false
          # If no association or field was found, check if the meth is an
          # _translations field.
          if obj.nil? & tr = meth.match(/(.*)_translations\z/)&.captures&.first
            is_translation = true
            meth = tr
          end

          # 1. If curr is an array fetch from all elements in the array.
          # 2. If the field is localized, and is not an _translations field
          #    (_translations fields don't show up in the fields hash).
          #    - If this is the end of the methods, return the translation for
          #      the current locale.
          #    - Otherwise, return the whole translations hash so the next method
          #      can select the language it wants.
          # 3. If the meth is an _translations field, do not demongoize the
          #    value so the full hash is returned.
          # 4. Otherwise, fetch and demongoize the value for the key meth.
          curr = if curr.is_a? Array
            res = curr.map { |x| fetch_and_demongoize(x, meth, k) }
            res.empty? ? nil : res
          elsif !is_translation && k.fields[meth]&.localized?
            if i < num_meths
              curr.try(:fetch, meth, nil)
            else
              fetch_and_demongoize(curr, meth, k)
            end
          elsif is_translation
            curr.try(:fetch, meth, nil)
          else
            fetch_and_demongoize(curr, meth, k)
          end

          # If it's a relation, update the current klass with the relation klass.
          if !is_field && !obj.nil?
            k = obj.klass
          end
          i += 1
        end
        curr
      end

      # Recursively demongoize the given value. This method recursively traverses
      # the class tree to find the correct field to use to demongoize the value.
      #
      # @param [ String ] field_name The name of the field to demongoize.
      # @param [ Object ] value The value to demongoize.
      # @param [ Boolean ] is_translation The field we are retrieving is an
      #   _translations field.
      #
      # @return [ Object ] The demongoized value.
      def recursive_demongoize(field_name, value, is_translation)
        field = klass.traverse_association_tree(field_name)

        if field
          # If it's a localized field that's not a hash, don't demongoize
          # again, we already have the translation. If it's an _translations
          # field, don't demongoize, we want the full hash not just a
          # specific translation.
          if field.localized? && (!value.is_a?(Hash) || is_translation)
            value.class.demongoize(value)
          else
            field.demongoize(value)
          end
        else
          value.class.demongoize(value)
        end
      end
    end
  end
end
