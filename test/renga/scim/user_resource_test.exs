defmodule Renga.Scim.UserResourceTest do
  use ExUnit.Case, async: true

  alias Renga.Scim.UserResource

  @current %{
    user_name: "sam@example.com",
    external_id: "00u1",
    display_name: "Sam",
    formatted_name: "Sam Lee",
    given_name: "Sam",
    family_name: "Lee",
    email: "sam@example.com",
    active: true
  }

  defp op(op, path, value \\ nil) do
    %{"op" => op, "path" => path, "value" => value}
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  describe "create/1" do
    test "reads the declared attributes and defaults active to true" do
      assert {:ok, attrs} =
               UserResource.create(%{
                 "userName" => " sam@example.com ",
                 "externalId" => "00u1",
                 "name" => %{"givenName" => "Sam", "familyName" => "Lee", "middleName" => "X"},
                 "emails" => [
                   %{"value" => "other@example.com", "type" => "home"},
                   %{"value" => "sam@example.com", "primary" => "True"}
                 ],
                 "title" => "Engineer",
                 "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User" => %{
                   "department" => "x"
                 }
               })

      assert attrs.user_name == "sam@example.com"
      assert attrs.external_id == "00u1"
      assert attrs.given_name == "Sam" and attrs.family_name == "Lee"
      assert attrs.email == "sam@example.com"
      assert attrs.active == true
    end

    test "an omitted, null, or empty externalId makes an unlinked entry" do
      for resource <- [%{}, %{"externalId" => nil}, %{"externalId" => ""}] do
        assert {:ok, %{external_id: nil}} =
                 UserResource.create(Map.put(resource, "userName", "sam"))
      end
    end

    test "accepts and discards a password" do
      assert {:ok, attrs} = UserResource.create(%{"userName" => "sam", "password" => "hunter2"})
      refute inspect(attrs) =~ "hunter2"
    end

    test "active must be a boolean or an accepted string" do
      for {value, expected} <- [{true, true}, {"False", false}, {"true", true}] do
        assert {:ok, %{active: ^expected}} =
                 UserResource.create(%{"userName" => "sam", "active" => value})
      end

      for value <- [nil, "yes", "FALSE", 0, "0"] do
        assert {:error, {:invalid_value, _}} =
                 UserResource.create(%{"userName" => "sam", "active" => value})
      end
    end

    test "requires a userName and matches attribute names without case" do
      assert {:error, {:invalid_value, "userName is required"}} = UserResource.create(%{})
      assert {:error, {:invalid_value, _}} = UserResource.create(%{"userName" => ""})
      assert {:ok, %{user_name: "sam"}} = UserResource.create(%{"username" => "sam"})
    end
  end

  describe "replace/2" do
    test "omitted active keeps the current value; other omissions clear" do
      current = %{@current | active: false}
      assert {:ok, attrs} = UserResource.replace(%{"userName" => "sam"}, current)
      assert attrs.active == false
      assert attrs.external_id == nil and attrs.email == nil and attrs.given_name == nil
    end

    test "refuses a password change" do
      assert {:error, {:invalid_value, _}} =
               UserResource.replace(%{"userName" => "sam", "password" => "x"}, @current)
    end

    test "refuses a null active" do
      assert {:error, {:invalid_value, _}} =
               UserResource.replace(%{"userName" => "sam", "active" => nil}, @current)
    end
  end

  describe "patch/2" do
    test "Entra's title-case operations and string booleans" do
      assert {:ok, %{active: false}} =
               UserResource.patch([op("Replace", "active", "False")], @current)

      assert {:ok, %{active: true}} =
               UserResource.patch([op("Replace", "active", "True")], %{@current | active: false})
    end

    test "Okta's path-less replace" do
      assert {:ok, %{active: false}} =
               UserResource.patch([op("replace", nil, %{"active" => false})], @current)
    end

    test "active can only be replaced with an explicit boolean" do
      for operation <- [
            op("replace", "active"),
            op("replace", "active", "no"),
            op("remove", "active")
          ] do
        assert {:error, {:invalid_value, _}} = UserResource.patch([operation], @current)
      end
    end

    test "externalId add, replace, and remove follow the binding rules" do
      assert {:ok, %{external_id: "00u2"}} =
               UserResource.patch([op("Add", "externalId", "00u2")], @current)

      assert {:ok, %{external_id: nil}} =
               UserResource.patch([op("replace", "externalId", "")], @current)

      assert {:ok, %{external_id: nil}} =
               UserResource.patch([op("remove", "externalId")], @current)
    end

    test "names, emails, and value-filtered paths" do
      assert {:ok, attrs} =
               UserResource.patch(
                 [
                   op("Replace", "name.givenName", "Samantha"),
                   op("Replace", ~s(emails[type eq "work"].value), "s@example.com"),
                   op("Replace", "displayName", "Samantha Lee"),
                   op(
                     "Add",
                     "urn:ietf:params:scim:schemas:core:2.0:User:userName",
                     "s@example.com"
                   )
                 ],
                 @current
               )

      assert attrs.given_name == "Samantha"
      assert attrs.email == "s@example.com"
      assert attrs.display_name == "Samantha Lee"
      assert attrs.user_name == "s@example.com"

      assert {:ok, %{email: nil}} = UserResource.patch([op("remove", "emails")], @current)

      assert {:ok, %{formatted_name: nil, given_name: nil}} =
               UserResource.patch([op("remove", "name")], @current)
    end

    test "undeclared attributes and extensions are accepted and not kept" do
      assert {:ok, attrs} =
               UserResource.patch(
                 [
                   op("Add", "title", "Engineer"),
                   op(
                     "Replace",
                     "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User:department",
                     "Ops"
                   )
                 ],
                 @current
               )

      assert attrs == @current
    end

    test "refuses passwords, read-only groups, and malformed operations" do
      assert {:error, {:invalid_value, _}} =
               UserResource.patch([op("replace", "password", "x")], @current)

      assert {:error, {:mutability, _}} =
               UserResource.patch([op("add", "groups", [%{"value" => "g"}])], @current)

      assert {:error, {:no_target, _}} = UserResource.patch([op("remove", nil)], @current)

      assert {:error, {:invalid_syntax, _}} =
               UserResource.patch([op("move", "active", true)], @current)

      assert {:error, {:invalid_path, _}} =
               UserResource.patch([op("replace", "a b", 1)], @current)

      assert {:error, {:invalid_value, _}} =
               UserResource.patch([op("remove", "userName")], @current)
    end

    test "stops at the first failing operation" do
      assert {:error, {:invalid_value, _}} =
               UserResource.patch(
                 [op("replace", "displayName", "New"), op("replace", "active", "maybe")],
                 @current
               )
    end
  end
end
