defmodule Renga.Scim.UserResource do
  @moduledoc """
  Turns SCIM User requests into directory entry attributes, following RFD
  16's write rules ("Directory entries") rather than any one provider's
  idea of PUT:

    * `externalId`: omitted, null, or empty means none. On PUT that clears
      it; PATCH add and replace follow PUT, and remove clears it. Any other
      string is kept exactly, untrimmed, since it is correlation evidence.
    * `active`: omitted on POST means `true`; omitted on PUT keeps the
      current value; PATCH may only replace it with an explicit boolean.
      Null or any value other than a boolean or its accepted string form is
      `invalidValue`.
    * `password`: accepted and discarded on POST, so Okta can provision;
      any attempt to change it on PUT or PATCH is `invalidValue`.
    * `groups` is read-only.

  Attributes Renga does not declare, including extension schemas, are
  accepted and not kept. Errors are `{:error, {scim_type, detail}}`, where
  `scim_type` is RFC 7644's keyword as an atom.
  """

  alias Renga.Scim.Attributes
  alias Renga.Scim.Path

  @core "urn:ietf:params:scim:schemas:core:2.0:User"
  @email_filter ~r/^\s*(value|type)\s+eq\s+("(?:[^"\\]|\\.)*")\s*$/i

  @doc "Attributes for a new entry from a POST body."
  def create(resource) when is_map(resource) do
    with {:ok, attrs} <- common(resource),
         {:ok, active} <- active(resource, true) do
      {:ok, Map.put(attrs, :active, active)}
    end
  end

  def create(_resource), do: invalid_syntax()

  @doc "Attributes replacing `current`'s from a PUT body."
  def replace(resource, current) when is_map(resource) do
    with :ok <- refuse_password(resource),
         {:ok, attrs} <- common(resource),
         {:ok, active} <- active(resource, current.active) do
      {:ok, Map.put(attrs, :active, active)}
    end
  end

  def replace(_resource, _current), do: invalid_syntax()

  @doc """
  Attributes after applying PATCH `operations` to `current`, in order. An
  operation's `op` is matched without case, as Entra sends `Replace`.
  """
  def patch(operations, current) when is_list(operations) do
    Enum.reduce_while(operations, {:ok, attributes(current)}, fn operation, {:ok, attrs} ->
      case operation(operation, attrs) do
        {:ok, attrs} -> {:cont, {:ok, attrs}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def patch(_operations, _current), do: invalid_syntax()

  defp attributes(current), do: Map.take(current, Renga.Scim.DirectoryUser.fields())

  ## POST and PUT

  defp common(resource) do
    name = Attributes.get(resource, "name")

    with {:ok, user_name} <- user_name(Attributes.get(resource, "userName")),
         {:ok, external_id} <- external_id("replace", Attributes.get(resource, "externalId")),
         {:ok, display_name} <- string(resource, "displayName"),
         :ok <- complex(name, "name"),
         {:ok, formatted} <- string(name || %{}, "formatted"),
         {:ok, given} <- string(name || %{}, "givenName"),
         {:ok, family} <- string(name || %{}, "familyName"),
         {:ok, email} <- email(Attributes.get(resource, "emails")) do
      {:ok,
       %{
         user_name: user_name,
         external_id: external_id,
         display_name: display_name,
         formatted_name: formatted,
         given_name: given,
         family_name: family,
         email: email
       }}
    end
  end

  defp active(resource, default) do
    case Attributes.fetch(resource, "active") do
      :error -> {:ok, default}
      {:ok, value} -> boolean(value, "active")
    end
  end

  defp refuse_password(resource) do
    case Attributes.fetch(resource, "password") do
      :error -> :ok
      {:ok, _value} -> password_change()
    end
  end

  ## PATCH

  defp operation(%{} = operation, attrs) do
    with {:ok, op} <- Attributes.op(operation) do
      targeted(op, Attributes.get(operation, "path"), Attributes.get(operation, "value"), attrs)
    end
  end

  defp operation(_operation, _attrs),
    do: {:error, {:invalid_syntax, "Each operation must be an object"}}

  defp targeted("remove", path, _value, _attrs) when path in [nil, ""],
    do: {:error, {:no_target, "A remove operation needs a path"}}

  defp targeted(_op, path, value, attrs) when path in [nil, ""], do: pathless(value, attrs)

  defp targeted(_op, path, _value, _attrs) when not is_binary(path),
    do: {:error, {:invalid_path, "The path must be a string"}}

  defp targeted(op, path, value, attrs) do
    case Path.parse(path, @core) do
      {:ok, parsed} -> apply_path(op, parsed, value, attrs)
      :extension -> {:ok, attrs}
      :error -> {:error, {:invalid_path, "#{path} is not a valid path"}}
    end
  end

  # Without a path, the value is an object of attributes to set (Okta sends
  # {"active": false} this way).
  defp pathless(value, attrs) when is_map(value) do
    Enum.reduce_while(value, {:ok, attrs}, fn {key, attribute_value}, {:ok, attrs} ->
      parsed =
        case Path.parse(key, @core) do
          {:ok, parsed} -> {:ok, parsed}
          :extension -> :extension
          :error -> {:error, {:invalid_path, "#{key} is not a valid attribute"}}
        end

      result =
        case parsed do
          {:ok, parsed} -> apply_path("replace", parsed, attribute_value, attrs)
          :extension -> {:ok, attrs}
          {:error, _reason} = error -> error
        end

      case result do
        {:ok, attrs} -> {:cont, {:ok, attrs}}
        error -> {:halt, error}
      end
    end)
  end

  defp pathless(_value, _attrs),
    do: {:error, {:invalid_value, "An operation without a path needs an object value"}}

  defp apply_path(op, %{attribute: "username", filter: nil, sub: nil}, value, attrs) do
    if op == "remove" do
      {:error, {:invalid_value, "userName is required"}}
    else
      with {:ok, user_name} <- user_name(value), do: {:ok, %{attrs | user_name: user_name}}
    end
  end

  defp apply_path(op, %{attribute: "externalid", filter: nil, sub: nil}, value, attrs) do
    with {:ok, external_id} <- external_id(op, value),
         do: {:ok, %{attrs | external_id: external_id}}
  end

  defp apply_path(op, %{attribute: "active", filter: nil, sub: nil}, value, attrs) do
    if op == "remove" do
      {:error, {:invalid_value, "active can only be replaced with a boolean"}}
    else
      with {:ok, active} <- boolean(value, "active"), do: {:ok, %{attrs | active: active}}
    end
  end

  defp apply_path(op, %{attribute: "displayname", filter: nil, sub: nil}, value, attrs) do
    with {:ok, display_name} <- optional(op, value, "displayName"),
         do: {:ok, %{attrs | display_name: display_name}}
  end

  defp apply_path("remove", %{attribute: "name", filter: nil, sub: nil}, _value, attrs),
    do: {:ok, %{attrs | formatted_name: nil, given_name: nil, family_name: nil}}

  defp apply_path(op, %{attribute: "name", filter: nil, sub: nil}, value, attrs)
       when is_map(value) do
    Enum.reduce_while(value, {:ok, attrs}, fn {key, sub_value}, {:ok, attrs} ->
      case apply_path(
             op,
             %{attribute: "name", filter: nil, sub: String.downcase(key)},
             sub_value,
             attrs
           ) do
        {:ok, attrs} -> {:cont, {:ok, attrs}}
        error -> {:halt, error}
      end
    end)
  end

  defp apply_path(_op, %{attribute: "name", filter: nil, sub: nil}, _value, _attrs),
    do: {:error, {:invalid_value, "name must be an object"}}

  defp apply_path(op, %{attribute: "name", filter: nil, sub: sub}, value, attrs) do
    case Map.fetch(
           %{
             "formatted" => :formatted_name,
             "givenname" => :given_name,
             "familyname" => :family_name
           },
           sub
         ) do
      {:ok, field} ->
        with {:ok, string} <- optional(op, value, "name.#{sub}"),
             do: {:ok, Map.put(attrs, field, string)}

      # Other name parts, such as middleName, are not kept.
      :error ->
        {:ok, attrs}
    end
  end

  # A filtered path selects the one address Renga keeps by its value, or
  # by type, as Entra replaces emails[type eq "work"].value: Renga keeps no
  # type, so any type selects it. A value naming another address selects
  # nothing, and no other filter can be evaluated.
  defp apply_path(op, %{attribute: "emails", filter: filter, sub: sub}, value, attrs)
       when is_binary(filter) do
    case email_selector(filter, attrs.email) do
      :selected ->
        apply_email(op, sub, value, attrs)

      :other when op == "remove" ->
        {:ok, attrs}

      :other ->
        {:error, {:no_target, "No email address matches #{filter}"}}

      :unsupported ->
        {:error, {:invalid_filter, ~s(Emails can only be filtered by value eq or type eq)}}
    end
  end

  defp apply_path(op, %{attribute: "emails", sub: sub}, value, attrs),
    do: apply_email(op, sub, value, attrs)

  defp apply_path(_op, %{attribute: "password"}, _value, _attrs), do: password_change()

  defp apply_path(_op, %{attribute: attribute}, _value, _attrs)
       when attribute in ["groups", "id", "meta"],
       do: {:error, {:mutability, "#{attribute} is read-only"}}

  # The schemas attribute and undeclared attributes, such as title or
  # phoneNumbers, are accepted and not kept.
  defp apply_path(_op, _path, _value, attrs), do: {:ok, attrs}

  ## Values

  defp user_name(value) do
    case Attributes.optional_string(value) do
      {:ok, nil} -> {:error, {:invalid_value, "userName is required"}}
      {:ok, user_name} -> {:ok, user_name}
      :error -> {:error, {:invalid_value, "userName must be a string"}}
    end
  end

  defp optional("remove", _value, _name), do: {:ok, nil}

  defp optional(_op, value, name) do
    case Attributes.optional_string(value) do
      {:ok, string} -> {:ok, string}
      :error -> {:error, {:invalid_value, "#{name} must be a string"}}
    end
  end

  defp string(map, name), do: optional("replace", Attributes.get(map, name), name)

  # externalId is correlation evidence, compared exactly with an ID token
  # claim, so it is kept as sent: only null and the empty string mean none.
  defp external_id("remove", _value), do: {:ok, nil}
  defp external_id(_op, value) when value in [nil, ""], do: {:ok, nil}
  defp external_id(_op, value) when is_binary(value), do: {:ok, value}
  defp external_id(_op, _value), do: {:error, {:invalid_value, "externalId must be a string"}}

  defp complex(nil, _name), do: :ok
  defp complex(value, _name) when is_map(value), do: :ok
  defp complex(_value, name), do: {:error, {:invalid_value, "#{name} must be an object"}}

  defp boolean(value, name) do
    case Attributes.boolean(value) do
      {:ok, boolean} -> {:ok, boolean}
      :error -> {:error, {:invalid_value, "#{name} must be a boolean"}}
    end
  end

  # Renga keeps one address: the primary one, or else the first.
  defp email(nil), do: {:ok, nil}

  defp email(emails) when is_list(emails) do
    if Enum.all?(emails, &is_map/1) do
      chosen =
        Enum.find(emails, &(Attributes.boolean(Attributes.get(&1, "primary")) == {:ok, true})) ||
          List.first(emails)

      optional("replace", chosen && Attributes.get(chosen, "value"), "emails.value")
    else
      {:error, {:invalid_value, "emails must be a list of objects"}}
    end
  end

  defp email(_emails), do: {:error, {:invalid_value, "emails must be a list"}}

  # Removing the address or its value clears it; removing a sub-attribute
  # Renga does not keep, such as type, leaves it.
  defp apply_email("remove", sub, _value, attrs) when sub in [nil, "value"],
    do: {:ok, %{attrs | email: nil}}

  defp apply_email("remove", _sub, _value, attrs), do: {:ok, attrs}

  defp apply_email(_op, "value", value, attrs) do
    with {:ok, email} <- optional("replace", value, "emails.value"),
         do: {:ok, %{attrs | email: email}}
  end

  defp apply_email(_op, nil, value, attrs) do
    with {:ok, email} <- email(List.wrap(value)), do: {:ok, %{attrs | email: email}}
  end

  defp apply_email(_op, _sub, _value, attrs), do: {:ok, attrs}

  # The compared value is a JSON string literal (RFC 7644, section 3.4.2.2),
  # so an invalid escape makes the filter unreadable rather than matching.
  defp email_selector(filter, email) do
    with [_match, attribute, literal] <- Regex.run(@email_filter, filter),
         {:ok, value} when is_binary(value) <- Jason.decode(literal) do
      cond do
        String.downcase(attribute) == "type" -> :selected
        is_binary(email) and String.downcase(value) == String.downcase(email) -> :selected
        true -> :other
      end
    else
      _unreadable -> :unsupported
    end
  end

  defp password_change,
    do: {:error, {:invalid_value, "Renga accounts' passwords cannot be changed through SCIM"}}

  defp invalid_syntax, do: {:error, {:invalid_syntax, "The request body must be a JSON object"}}
end
