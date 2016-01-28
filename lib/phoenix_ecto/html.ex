if Code.ensure_loaded?(Phoenix.HTML) do
  defimpl Phoenix.HTML.FormData, for: Ecto.Changeset do
    def to_form(%Ecto.Changeset{params: params} = changeset, opts) do
      {name, opts} = Keyword.pop(opts, :as)
      data = get_data(changeset)
      name = to_string(name || warn_name(opts) || form_for_name(data))

      %Phoenix.HTML.Form{
        source: changeset,
        impl: __MODULE__,
        id: name,
        name: name,
        errors: changeset.errors,
        data: data,
        params: params || %{},
        hidden: form_for_hidden(data),
        options: Keyword.put_new(opts, :method, form_for_method(data))
      }
    end

    def to_form(source, form, field, opts) do
      if Keyword.has_key?(opts, :default) do
        raise ArgumentError, ":default is not supported on inputs_for with changesets. " <>
                             "The default value must be set in the changeset data"
      end

      if Keyword.has_key?(opts, :skip_deleted) do
        IO.write :stderr, "warning: :skip_deleted in inputs_for is deprecated\n" <>
                          Exception.format_stacktrace
      end

      {skip_deleted, opts} = Keyword.pop(opts, :skip_deleted, nil)
      {prepend, opts} = Keyword.pop(opts, :prepend, [])
      {append, opts} = Keyword.pop(opts, :append, [])
      {name, opts} = Keyword.pop(opts, :as)
      {id, opts} = Keyword.pop(opts, :id)

      id    = to_string(id || form.id <> "_#{field}")
      name  = to_string(name || warn_name(opts) || form.name <> "[#{field}]")

      case find_inputs_for_type!(source, field) do
        {:one, cast, module} ->
          changesets =
            case Map.fetch(source.changes, field) do
              {:ok, nil} when skip_deleted in [false, nil] -> []
              {:ok, map} when not is_nil(map) -> [validate_map!(map, field)]
              _  ->
                [validate_map!(assoc_from_data(get_data(source), field), field) || module.__struct__]
            end

          for changeset <- skip_deleted(changesets, skip_deleted) do
            changeset = to_changeset(changeset, module, cast)
            data = get_data(changeset)

            %Phoenix.HTML.Form{
              source: changeset,
              impl: __MODULE__,
              id: id,
              name: name,
              errors: changeset.errors,
              data: data,
              params: changeset.params || %{},
              hidden: form_for_hidden(data),
              options: opts
            }
          end

        {:many, cast, module} ->
          changesets =
            validate_list!(Map.get(source.changes, field), field) ||
            validate_list!(assoc_from_data(get_data(source), field), field) ||
            []

          changesets =
            if form.params[Atom.to_string(field)] do
              changesets
            else
              prepend ++ changesets ++ append
            end

          changesets = skip_deleted(changesets, skip_deleted)

          for {changeset, index} <- Enum.with_index(changesets) do
            changeset = to_changeset(changeset, module, cast)
            data = get_data(changeset)
            index_string = Integer.to_string(index)

            %Phoenix.HTML.Form{
              source: changeset,
              impl: __MODULE__,
              id: id <> "_" <> index_string,
              name: name <> "[" <> index_string <> "]",
              index: index,
              errors: changeset.errors,
              data: data,
              params: changeset.params || %{},
              hidden: form_for_hidden(data),
              options: opts
            }
          end
      end
    end

    def input_type(changeset, field) do
      type = Map.get(changeset.types, field, :string)
      type = if Ecto.Type.primitive?(type), do: type, else: type.type

      case type do
        :integer  -> :number_input
        :float    -> :number_input
        :decimal  -> :number_input
        :boolean  -> :checkbox
        :date     -> :date_select
        :time     -> :time_select
        :datetime -> :datetime_select
        _         -> :text_input
      end
    end

    def input_validations(changeset, field) do
      [required: field in changeset.required] ++
        for({key, validation} <- changeset.validations,
            key == field,
            attr <- validation_to_attrs(validation, field, changeset),
            do: attr)
    end

    defp assoc_from_data(data, field) do
      assoc_from_data(data, Map.fetch!(data, field), field)
    end

    defp assoc_from_data(%{__meta__: %{state: :built}}, %Ecto.Association.NotLoaded{}, _field), do: nil

    defp assoc_from_data(%{__struct__: struct}, %Ecto.Association.NotLoaded{}, field) do
      raise ArgumentError, "using inputs_for for association `#{field}` " <>
        "from `#{inspect struct}` but it was not loaded. Please preload your " <>
        "associations before using them in inputs_for"
    end

    defp assoc_from_data(_data, value, _field) do
      value
    end

    # TODO: Make me skip only replaced
    defp skip_deleted(changesets, skip_deleted) do
      Enum.reject(changesets, fn
        %Ecto.Changeset{action: :replace} -> true
        %Ecto.Changeset{action: :delete} when skip_deleted == true -> true
        _ -> false
      end)
    end

    defp validation_to_attrs({:length, opts}, _field, _changeset) do
      max =
        if val = Keyword.get(opts, :max) do
          [maxlength: val]
        else
          []
        end

      min =
        if val = Keyword.get(opts, :min) do
          [minlength: val]
        else
          []
        end

      max ++ min
    end

    defp validation_to_attrs({:number, opts}, field, changeset) do
      type = Map.get(changeset.types, field, :integer)
      step_for(type) ++ min_for(type, opts) ++ max_for(type, opts)
    end

    defp validation_to_attrs(_validation, _field, _changeset) do
      []
    end

    defp step_for(:integer), do: [step: 1]
    defp step_for(_other),   do: [step: "any"]

    defp max_for(type, opts) do
      cond do
        (type == :integer) && (max = Keyword.get(opts, :less_than)) ->
          [max: max - 1]
        max = Keyword.get(opts, :less_than_or_equal_to) ->
          [max: max]
        true ->
          []
      end
    end

    defp min_for(type, opts) do
      cond do
        (type == :integer) && (min = Keyword.get(opts, :greater_than)) ->
          [min: min + 1]
        min = Keyword.get(opts, :greater_than_or_equal_to) ->
          [min: min]
        true ->
          []
      end
    end

    defp find_inputs_for_type!(changeset, field) do
      # TODO: Remove on_cast once we support only Ecto 2.0
      case Map.fetch(changeset.types, field) do
        {:ok, {tag, %{cardinality: cardinality, on_cast: cast, related: module}}} when tag in [:embed, :assoc] ->
          {cardinality, cast, module}
        {:ok, {tag, %{cardinality: cardinality, related: module}}} when tag in [:embed, :assoc] ->
          {cardinality, nil, module}
        _ ->
          raise ArgumentError,
            "could not generate inputs for #{inspect field} from #{inspect changeset.data.__struct__}. " <>
            "Check the field exists and it is one of embeds_one, embeds_many, has_one, " <>
            "has_many, belongs_to or many_to_many"
      end
    end

    # TODO: Remove on_cast once we support only Ecto 2.0
    defp to_changeset(%Ecto.Changeset{} = changeset, _module, _cast), do: changeset
    defp to_changeset(%{} = data, _module, nil), do: Ecto.Changeset.change(data)
    defp to_changeset(%{} = data, module, cast), do: apply(module, cast, [data, :empty])

    defp validate_list!(value, _what) when is_list(value) or is_nil(value), do: value
    defp validate_list!(value, what) do
      raise ArgumentError, "expected #{what} to be a list, got: #{inspect value}"
    end

    defp validate_map!(value, _what) when is_map(value) or is_nil(value), do: value
    defp validate_map!(value, what) do
      raise ArgumentError, "expected #{what} to be a map/struct, got: #{inspect value}"
    end

    defp form_for_hidden(data) do
      # Since they are primary keys, we should ignore nil values.
      for {k, v} <- Ecto.primary_key(data), v != nil, do: {k, v}
    end

    defp form_for_name(%{__struct__: module}) do
      module
      |> Module.split()
      |> List.last()
      |> underscore()
    end

    defp form_for_method(%{__meta__: %{state: :loaded}}), do: "put"
    defp form_for_method(_), do: "post"

    defp warn_name(opts) do
      if name = Keyword.get(opts, :name) do
        IO.write :stderr, "the :name option in form_for/inputs_for is deprecated, " <>
                          "please use :as instead\n" <> Exception.format_stacktrace()
        name
      end
    end

    # TODO: Remove model once we support only Ecto 2.0 (Elixir 1.2 only)
    defp get_data(%{model: model}), do: model
    defp get_data(%{data: data}), do: data

    # TODO: Remove underscore once we support only Ecto 2.0 (Elixir 1.2 only)
    defp underscore(<<>>), do: ""

    defp underscore(<<h, t :: binary>>) do
      <<to_lower_char(h)>> <> do_underscore(t, h)
    end

    defp do_underscore(<<h, t, rest :: binary>>, _) when h in ?A..?Z and not t in ?A..?Z do
      <<?_, to_lower_char(h), t>> <> do_underscore(rest, t)
    end

    defp do_underscore(<<h, t :: binary>>, prev) when h in ?A..?Z and not prev in ?A..?Z do
      <<?_, to_lower_char(h)>> <> do_underscore(t, h)
    end

    defp do_underscore(<<h, t :: binary>>, _) do
      <<to_lower_char(h)>> <> do_underscore(t, h)
    end

    defp do_underscore(<<>>, _) do
      <<>>
    end

    defp to_lower_char(char) when char in ?A..?Z, do: char + 32
    defp to_lower_char(char), do: char
  end

  defimpl Phoenix.HTML.Safe, for: [Decimal, Ecto.Time, Ecto.Date, Ecto.DateTime] do
    def to_iodata(t) do
      @for.to_string(t)
    end
  end
end
