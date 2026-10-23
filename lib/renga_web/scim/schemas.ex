defmodule RengaWeb.Scim.Schemas do
  @moduledoc """
  The SCIM schemas and resource types Renga serves (RFC 7643, sections 6
  and 7). They declare only the attributes Renga stores; a provider's
  attributes outside them are accepted and not kept (RFD 16, "Directory
  entries").
  """

  use RengaWeb, :verified_routes

  @user "urn:ietf:params:scim:schemas:core:2.0:User"
  @group "urn:ietf:params:scim:schemas:core:2.0:Group"
  @schema "urn:ietf:params:scim:schemas:core:2.0:Schema"
  @resource_type "urn:ietf:params:scim:schemas:core:2.0:ResourceType"
  @service_provider_config "urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"
  @list_response "urn:ietf:params:scim:api:messages:2.0:ListResponse"

  @max_results 100

  def user_schema, do: @user
  def group_schema, do: @group
  def list_response_schema, do: @list_response

  @doc "The most resources one page of a list returns."
  def max_results, do: @max_results

  @doc "The `ServiceProviderConfig` resource."
  def service_provider_config do
    %{
      "schemas" => [@service_provider_config],
      "patch" => %{"supported" => true},
      "bulk" => %{"supported" => false, "maxOperations" => 0, "maxPayloadSize" => 0},
      "filter" => %{"supported" => true, "maxResults" => @max_results},
      "changePassword" => %{"supported" => false},
      "sort" => %{"supported" => false},
      "etag" => %{"supported" => false},
      "authenticationSchemes" => [
        %{
          "type" => "oauthbearertoken",
          "name" => "Bearer token",
          "description" =>
            "A token an organization owner issues for the SCIM connection, sent as " <>
              "Authorization: Bearer <token>",
          "specUri" => "https://www.rfc-editor.org/rfc/rfc6750",
          "primary" => true
        }
      ],
      "meta" => %{
        "resourceType" => "ServiceProviderConfig",
        "location" => url(~p"/scim/v2/ServiceProviderConfig")
      }
    }
  end

  @doc "Every resource type, as `ResourceType` resources."
  def resource_types, do: [resource_type("User"), resource_type("Group")]

  @doc "One resource type by name, or nil."
  def resource_type("User"), do: resource_type("User", "/Users", @user)
  def resource_type("Group"), do: resource_type("Group", "/Groups", @group)
  def resource_type(_name), do: nil

  defp resource_type(name, endpoint, schema) do
    %{
      "schemas" => [@resource_type],
      "id" => name,
      "name" => name,
      "endpoint" => endpoint,
      "schema" => schema,
      "schemaExtensions" => [],
      "meta" => %{
        "resourceType" => "ResourceType",
        "location" => url(~p"/scim/v2/ResourceTypes/#{name}")
      }
    }
  end

  @doc "Every schema, as `Schema` resources."
  def schemas, do: [schema(@user), schema(@group)]

  @doc "One schema by URN, or nil."
  def schema(@user) do
    schema_resource(@user, "User", "User Account", [
      attribute("userName", "string",
        required: true,
        uniqueness: "server",
        description: "Unique identifier for the user within the connection"
      ),
      complex("name", "The components of the user's name", [
        attribute("formatted", "string", description: "The full name"),
        attribute("familyName", "string", description: "The family name"),
        attribute("givenName", "string", description: "The given name")
      ]),
      attribute("displayName", "string", description: "The name displayed to people"),
      complex(
        "emails",
        "Email addresses; Renga keeps the primary one",
        [
          attribute("value", "string", description: "The address"),
          attribute("type", "string", description: "A label such as work"),
          attribute("primary", "boolean", description: "Whether this is the primary address")
        ],
        multi_valued: true
      ),
      attribute("active", "boolean", description: "Whether the user is active"),
      complex(
        "groups",
        "The groups the user belongs to",
        [
          attribute("value", "string", mutability: "readOnly", description: "The group's id"),
          attribute("$ref", "reference",
            mutability: "readOnly",
            reference_types: ["Group"],
            description: "The group's URI"
          ),
          attribute("display", "string", mutability: "readOnly", description: "The group's name")
        ],
        multi_valued: true,
        mutability: "readOnly"
      )
    ])
  end

  def schema(@group) do
    schema_resource(@group, "Group", "Group", [
      attribute("displayName", "string",
        required: true,
        uniqueness: "server",
        description: "The group's name, unique within the connection"
      ),
      complex(
        "members",
        "The users in the group",
        [
          attribute("value", "string", mutability: "immutable", description: "The user's id"),
          attribute("$ref", "reference",
            mutability: "immutable",
            reference_types: ["User"],
            description: "The user's URI"
          ),
          attribute("display", "string", mutability: "readOnly", description: "The user's name")
        ],
        multi_valued: true
      )
    ])
  end

  def schema(_id), do: nil

  defp schema_resource(id, name, description, attributes) do
    %{
      "schemas" => [@schema],
      "id" => id,
      "name" => name,
      "description" => description,
      "attributes" => attributes,
      "meta" => %{"resourceType" => "Schema", "location" => url(~p"/scim/v2/Schemas/#{id}")}
    }
  end

  defp attribute(name, type, opts) do
    %{
      "name" => name,
      "type" => type,
      "multiValued" => Keyword.get(opts, :multi_valued, false),
      "description" => Keyword.fetch!(opts, :description),
      "required" => Keyword.get(opts, :required, false),
      "caseExact" => false,
      "mutability" => Keyword.get(opts, :mutability, "readWrite"),
      "returned" => "default",
      "uniqueness" => Keyword.get(opts, :uniqueness, "none")
    }
    |> then(fn attribute ->
      case opts[:reference_types] do
        nil -> attribute
        types -> Map.put(attribute, "referenceTypes", types)
      end
    end)
  end

  defp complex(name, description, sub_attributes, opts \\ []) do
    name
    |> attribute("complex", Keyword.put(opts, :description, description))
    |> Map.put("subAttributes", sub_attributes)
  end
end
