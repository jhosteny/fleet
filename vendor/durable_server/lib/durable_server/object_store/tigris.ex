defmodule DurableServer.ObjectStore.Tigris do
  @moduledoc """
  Tigris-specific bucket provisioning and IAM bootstrap helpers.

  This module is intentionally separate from `DurableServer.ObjectStore` so the
  main object storage client can stay S3-compatible and generic.
  """

  require Logger

  import SweetXml

  alias DurableServer.ObjectStore
  alias Req

  @derive {Inspect, only: [:object_store, :iam_endpoint]}
  defstruct object_store: nil,
            iam_endpoint: nil

  @valid_new_opts [:iam_endpoint]

  def new(%__MODULE__{} = config, opts) when is_list(opts) do
    opts = Keyword.validate!(opts, @valid_new_opts)
    %{config | iam_endpoint: Keyword.get(opts, :iam_endpoint, config.iam_endpoint)}
  end

  def new(%ObjectStore{} = object_store, opts) when is_list(opts) do
    opts = Keyword.validate!(opts, @valid_new_opts)
    %__MODULE__{
      object_store: object_store,
      iam_endpoint: Keyword.fetch!(opts, :iam_endpoint)
    }
  end

  def new(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, [:object_store, :iam_endpoint])

    %__MODULE__{
      object_store: Keyword.fetch!(opts, :object_store),
      iam_endpoint: Keyword.fetch!(opts, :iam_endpoint)
    }
  end

  @doc """
  Creates a bucket and generates bucket-scoped credentials in a single operation.

  This is a convenience function that combines `create_bucket/2` and
  `generate_bucket_credentials/2`.
  """
  def create_bucket_with_credentials(%__MODULE__{} = config, bucket_name) do
    client = config.object_store

    case create_bucket(config, bucket_name) do
      {:ok, %{bucket: bucket}} ->
        case generate_bucket_credentials(config, bucket) do
          {:ok, credentials} ->
            %{
              access_key_id: access_key_id,
              secret_access_key: secret_access_key
            } = credentials

            {:ok,
             ObjectStore.new(client,
               bucket: bucket,
               access_key_id: access_key_id,
               secret_access_key: secret_access_key
             )}

          {:error, reason} ->
            {:error, {:credential_generation_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:bucket_creation_failed, reason}}
    end
  end

  @doc """
  Creates a bucket on the configured object storage endpoint.
  """
  def create_bucket(%__MODULE__{} = config, bucket_name, opts \\ []) do
    ObjectStore.create_bucket(config.object_store, bucket_name, opts)
  end

  @doc """
  Deletes a bucket using Tigris force-delete semantics.
  """
  def delete_bucket(%__MODULE__{} = config, bucket_name) do
    req =
      ObjectStore.new_req(config.object_store, consistent: true, headers: [{"tigris-force-delete", "true"}])

    case Req.request(req, method: :delete, url: "s3://#{bucket_name}") do
      {:ok, %{status: status}} when status >= 200 and status < 300 ->
        :ok

      {:error, reason} ->
        {:error, reason}

      {:ok, response} ->
        {:error, response}
    end
  end

  @doc """
  Generates bucket-scoped credentials for a bucket using the IAM API.
  """
  def generate_bucket_credentials(%__MODULE__{} = config, bucket_name) do
    random_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    user_name = "tid_#{random_id}"

    Logger.info("Creating access key for bucket: #{bucket_name}")
    access_key_result = create_access_key(config, user_name)

    case access_key_result do
      {:ok,
       %{access_key_id: access_key_id, secret_access_key: secret_access_key, user_name: _user_name}} ->
        policy_name = "bucket-policy-#{bucket_name}-#{random_id}"
        policy_document = create_bucket_policy_document(bucket_name)

        case create_policy(config, policy_name, policy_document) do
          {:ok, %{policy_arn: policy_arn}} ->
            attach_user_name = access_key_id

            case attach_user_policy(config, attach_user_name, policy_arn) do
              :ok ->
                {:ok,
                 %{
                   access_key_id: access_key_id,
                   secret_access_key: secret_access_key,
                   bucket: bucket_name
                 }}

              {:error, reason} ->
                _ = delete_access_key(config, access_key_id)
                _ = delete_policy(config, policy_arn)
                {:error, {:attach_policy_failed, reason}}
            end

          {:error, reason} ->
            _ = delete_access_key(config, access_key_id)
            {:error, {:create_policy_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:create_access_key_failed, reason}}
    end
  end

  @doc """
  Lists IAM policies that match a given bucket name pattern.
  """
  def list_bucket_policies(%__MODULE__{} = config, bucket_name) do
    Logger.info("Listing IAM policies for bucket: #{bucket_name}")

    policy_prefix = "bucket-policy-#{bucket_name}"

    params = %{
      "Action" => "ListPolicies",
      "Version" => "2010-05-08",
      "PathPrefix" => "/"
    }

    case iam_request(config, params) do
      {:ok, %{body: xml_body}} ->
        policies =
          xml_body
          |> xpath(~x"//Policies/member"l)
          |> Enum.map(fn policy ->
            %{
              arn: xpath(policy, ~x"./Arn/text()"s),
              name: xpath(policy, ~x"./PolicyName/text()"s)
            }
          end)
          |> Enum.filter(fn policy ->
            String.contains?(policy.name, policy_prefix)
          end)

        {:ok, policies}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets detailed information about a specific IAM policy including the policy document.
  """
  def get_policy_details(%__MODULE__{} = config, policy_arn) do
    Logger.info("Getting policy details for: #{policy_arn}")

    get_policy_params = %{
      "Action" => "GetPolicy",
      "Version" => "2010-05-08",
      "PolicyArn" => policy_arn
    }

    with {:ok, %{body: policy_xml}} <- iam_request(config, get_policy_params),
         policy_name = policy_xml |> xpath(~x"//PolicyName/text()"s),
         default_version = policy_xml |> xpath(~x"//DefaultVersionId/text()"s),
         get_version_params = %{
           "Action" => "GetPolicyVersion",
           "Version" => "2010-05-08",
           "PolicyArn" => policy_arn,
           "VersionId" => default_version
         },
         {:ok, %{body: version_xml}} <- iam_request(config, get_version_params) do
      encoded_document = version_xml |> xpath(~x"//Document/text()"s)
      document = URI.decode(encoded_document)

      {:ok,
       %{
         arn: policy_arn,
         name: policy_name,
         document: document
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, %{errors: ["Failed to get complete policy details"]}}
    end
  end

  defp create_bucket_policy_document(bucket_name) do
    policy = %{
      "Version" => "2012-10-17",
      "Statement" => [
        %{
          "Sid" => "ListObjectsInBucket",
          "Effect" => "Allow",
          "Action" => ["s3:ListBucket"],
          "Resource" => ["arn:aws:s3:::#{bucket_name}"]
        },
        %{
          "Sid" => "ManageAllObjectsInBucketWildcard",
          "Effect" => "Allow",
          "Action" => ["s3:*"],
          "Resource" => ["arn:aws:s3:::#{bucket_name}/*"]
        }
      ]
    }

    JSON.encode!(policy)
  end

  defp iam_request(%__MODULE__{} = config, params) do
    client = config.object_store
    body = URI.encode_query(params)

    case Req.request(
           Keyword.merge(client.req_opts,
             method: :post,
             url: config.iam_endpoint,
             body: body,
             headers: [{"content-type", "application/x-www-form-urlencoded"}],
             retry: :transient,
             aws_sigv4: [
               access_key_id: client.access_key_id,
               secret_access_key: client.secret_access_key,
               service: :iam,
               region: client.region
             ]
           )
         ) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_access_key(config, user_name) do
    Logger.info("Creating access key for user: #{user_name}")

    params = %{
      "Action" => "CreateAccessKey",
      "Version" => "2010-05-08",
      "UserName" => user_name
    }

    case iam_request(config, params) do
      {:ok, %{body: xml_body} = result} ->
        try do
          Logger.debug(fn -> "Received CreateAccessKey response: #{inspect(xml_body)}" end)

          access_key_id = xml_body |> xpath(~x"//AccessKeyId/text()"s)
          secret_access_key = xml_body |> xpath(~x"//SecretAccessKey/text()"s)

          if access_key_id != "" and secret_access_key != "" do
            Logger.info("Successfully created access key with ID: #{access_key_id}")

            {:ok,
             %{
               access_key_id: access_key_id,
               secret_access_key: secret_access_key,
               user_name: user_name
             }}
          else
            {:error, {:invalid_response, "Missing access key information in response"}}
          end
        rescue
          error ->
            Logger.error(
              "Failed to parse CreateAccessKey XML response: #{inspect(error)} #{inspect(result)}"
            )

            {:error, {:xml_parse_error, error}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_policy(config, policy_name, policy_document) do
    Logger.info("Creating IAM policy: #{policy_name}")

    params = %{
      "Action" => "CreatePolicy",
      "Version" => "2010-05-08",
      "PolicyName" => policy_name,
      "PolicyDocument" => policy_document
    }

    case iam_request(config, params) do
      {:ok, %{body: xml_body}} when is_binary(xml_body) and xml_body != "" ->
        Logger.debug(
          "Received CreatePolicy response: #{inspect(String.slice(xml_body, 0, 100))}..."
        )

        try do
          policy_arn = xml_body |> xpath(~x"//Arn/text()"s)

          if policy_arn != "" do
            Logger.info("Successfully created policy with ARN: #{policy_arn}")
            {:ok, %{policy_arn: policy_arn}}
          else
            {:error, {:invalid_response, "Missing policy ARN in response"}}
          end
        catch
          kind, reason ->
            Logger.error(
              "Failed to parse CreatePolicy XML response: #{inspect(kind: kind, reason: reason, body: xml_body)}"
            )

            {:error, {:xml_parse_error, {kind, reason}}}
        end

      {:ok, %{body: xml_body}} ->
        Logger.error("CreatePolicy returned empty or invalid body: #{inspect(xml_body)}")
        {:error, {:invalid_response, "Empty or invalid response body"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp attach_user_policy(config, user_name, policy_arn) do
    Logger.info("Attaching policy #{policy_arn} to user: #{user_name}")

    params = %{
      "Action" => "AttachUserPolicy",
      "Version" => "2010-05-08",
      "UserName" => user_name,
      "PolicyArn" => policy_arn
    }

    case iam_request(config, params) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_access_key(config, access_key_id) do
    Logger.info("Deleting access key: #{access_key_id}")

    params = %{
      "Action" => "DeleteAccessKey",
      "Version" => "2010-05-08",
      "AccessKeyId" => access_key_id,
      "UserName" => access_key_id
    }

    case iam_request(config, params) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_policy(config, policy_arn) do
    Logger.info("Deleting policy: #{policy_arn}")

    detach_result = detach_user_policy(config, policy_arn)

    params = %{
      "Action" => "DeletePolicy",
      "Version" => "2010-05-08",
      "PolicyArn" => policy_arn
    }

    case iam_request(config, params) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:delete_policy_failed, reason, detach_result}}
    end
  end

  defp detach_user_policy(_config, policy_arn) do
    Logger.info("Detaching policy: #{policy_arn} from users")
    :ok
  end
end
