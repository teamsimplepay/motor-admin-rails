# frozen_string_literal: true

module Motor
  module BuildSchema
    module LoadFromRails
      MUTEX = Mutex.new
      UNIFIED_TYPES = ActiveRecordUtils::Types::UNIFIED_TYPES

      module_function

      def call
        models.map do |model|
          build_model_schema(model)
        rescue StandardError, NotImplementedError => e
          Rails.logger.error(e) if model.name != 'Audited::Audit'

          next
        end.compact
      end

      def models
        eager_load_models!

        models = ActiveRecord::Base.descendants.reject(&:abstract_class)

        models -= Motor::ApplicationRecord.descendants
        models -= [Motor::Audit]
        models -= [ActiveRecord::SchemaMigration] if defined?(ActiveRecord::SchemaMigration)
        models -= [ActiveStorage::Blob] if defined?(ActiveStorage::Blob)
        models -= [ActiveStorage::VariantRecord] if defined?(ActiveStorage::VariantRecord)

        models
      end

      def build_model_schema(model)
        model_name = model.name

        return Motor::BuildSchema::ACTIVE_STORAGE_ATTACHMENT_SCHEMA if model_name == 'ActiveStorage::Attachment'

        {
          name: model_name.underscore,
          slug: Utils.slugify(model),
          table_name: model.table_name,
          class_name: model.name,
          primary_key: model.primary_key,
          display_name: model_name.titleize.pluralize,
          display_column: FindDisplayColumn.call(model),
          columns: fetch_columns(model),
          associations: fetch_associations(model),
          scopes: fetch_scopes(model),
          actions: DEFAULT_ACTIONS,
          tabs: DEFAULT_TABS,
          visible: true
        }.with_indifferent_access
      end

      def fetch_scopes(model)
        model.defined_scopes.map do |scope_name|
          scope_name = scope_name.to_s

          next if scope_name.starts_with?('with_attached')

          {
            name: scope_name,
            display_name: scope_name.humanize,
            scope_type: DEFAULT_SCOPE_TYPE,
            visible: true,
            preferences: {}
          }
        end.compact
      end

      def fetch_columns(model)
        default_attrs = model.new.attributes

        reference_columns = fetch_reference_columns(model)

        table_columns =
          model.columns.map do |column|
            next if reference_columns.find { |c| c[:name] == column.name }

            build_table_column(column, model, default_attrs)
          end.compact

        reference_columns + table_columns
      end

      def build_table_column(column, model, default_attrs)
        is_enum = model.defined_enums[column.name]

        {
          name: column.name,
          display_name: column.name.humanize,
          column_type: is_enum ? 'string' : UNIFIED_TYPES[column.type.to_s] || column.type.to_s,
          is_array: column.array?,
          access_type: COLUMN_NAME_ACCESS_TYPES.fetch(column.name, ColumnAccessTypes::READ_WRITE),
          default_value: default_attrs[column.name],
          validators: fetch_validators(model, column.name),
          reference: nil,
          format: {},
          virtual: false
        }
      end

      def fetch_reference_columns(model)
        default_attrs = model.new.attributes

        model.reflections.map do |name, ref|
          next if !ref.has_one? && !ref.belongs_to?

          begin
            ref.klass
          rescue StandardError
            next
          end

          next if ref.klass.name == 'ActiveStorage::Blob'

          build_reflection_column(name, model, ref, default_attrs)
        end.compact
      end

      def build_reflection_column(name, model, ref, default_attrs)
        column_name = ref.belongs_to? ? ref.foreign_key.to_s : name
        is_attachment = ref.klass.name == 'ActiveStorage::Attachment'
        access_type = ref.belongs_to? || is_attachment ? ColumnAccessTypes::READ_WRITE : ColumnAccessTypes::READ_ONLY

        {
          name: column_name,
          display_name: column_name.humanize,
          column_type: is_attachment ? 'file' : 'integer',
          access_type: access_type,
          default_value: default_attrs[column_name],
          validators: fetch_validators(model, column_name, ref),
          format: {},
          reference: {
            name: name,
            model_name: ref.klass.name.underscore,
            reference_type: ref.belongs_to? ? 'belongs_to' : 'has_one',
            foreign_key: ref.foreign_key,
            polymorphic: ref.polymorphic? || is_attachment
          },
          virtual: false
        }
      end

      def fetch_associations(model)
        model.reflections.map do |name, ref|
          next if ref.has_one? || ref.belongs_to?

          begin
            ref.klass
          rescue StandardError
            next
          end

          model_class = ref.klass

          next if model_class.name == 'ActiveStorage::Blob'

          {
            name: name,
            display_name: name.humanize,
            slug: name.underscore,
            model_name: model_class.name.underscore,
            foreign_key: ref.foreign_key,
            polymorphic: ref.polymorphic? || model_class.name == 'ActiveStorage::Attachment',
            visible: true
          }
        end.compact
      end

      def fetch_validators(model, column_name, reflection = nil)
        validators =
          if reflection&.belongs_to? && !reflection.options[:optional]
            [{ required: true }]
          else
            []
          end

        enum = model.defined_enums[column_name]

        validators += [{ includes: enum.keys }] if enum

        validators += model.validators_on(column_name).map do |validator|
          build_validator_hash(validator)
        end.compact

        validators.uniq
      end

      def build_validator_hash(validator)
        case validator
        when ActiveModel::Validations::InclusionValidator
          { includes: validator.send(:delimiter) }
        when ActiveRecord::Validations::PresenceValidator
          { required: true }
        when ActiveModel::Validations::FormatValidator
          { format: JsRegex.new(validator.options[:with]).to_h.slice(:source, :options) }
        when ActiveRecord::Validations::LengthValidator
          { length: validator.options }
        when ActiveModel::Validations::NumericalityValidator
          { numeric: validator.options }
        end
      end

      def eager_load_models!
        MUTEX.synchronize do
          if Rails::VERSION::MAJOR > 5 && defined?(Zeitwerk::Loader)
            Zeitwerk::Loader.eager_load_all
          else
            Rails.application.eager_load!
          end

          ActiveRecord::Base.descendants.each do |model|
            model.reflections.each do |_, ref|
              ref.klass
            rescue StandardError
              next
            end
          end
        end
      end
    end
  end
end
