defmodule Cortex.Orchestration.Config.ValidatorTest do
  use ExUnit.Case, async: true

  alias Cortex.Orchestration.Config
  alias Cortex.Orchestration.Config.{Defaults, Lead, Member, Task, Team}
  alias Cortex.Orchestration.Config.Validator

  # --- Helpers ---

  defp valid_config do
    %Config{
      name: "test-project",
      defaults: %Defaults{},
      teams: [
        %Team{
          name: "backend",
          lead: %Lead{role: "Backend Lead"},
          tasks: [
            %Task{
              summary: "Build API",
              details: "Create REST endpoints",
              verify: "go test ./..."
            }
          ],
          depends_on: []
        }
      ]
    }
  end

  defp multi_team_config do
    %Config{
      name: "multi-project",
      defaults: %Defaults{},
      teams: [
        %Team{
          name: "shared",
          lead: %Lead{role: "Shared Lead"},
          tasks: [%Task{summary: "Build shared", details: "Libs", verify: "make test"}],
          depends_on: []
        },
        %Team{
          name: "api",
          lead: %Lead{role: "API Lead"},
          tasks: [%Task{summary: "Build API", details: "REST", verify: "go test"}],
          depends_on: ["shared"]
        },
        %Team{
          name: "web",
          lead: %Lead{role: "Web Lead"},
          tasks: [%Task{summary: "Build web", details: "React", verify: "npm test"}],
          depends_on: ["shared"]
        },
        %Team{
          name: "integration",
          lead: %Lead{role: "Integration Lead"},
          tasks: [
            %Task{summary: "Integration tests", details: "E2E", verify: "make integration"}
          ],
          depends_on: ["api", "web"]
        }
      ]
    }
  end

  # --- Hard Error Tests ---

  describe "validate/1 — hard errors" do
    test "valid config passes" do
      assert {:ok, %Config{}, warnings} = Validator.validate(valid_config())
      assert is_list(warnings)
    end

    test "valid multi-team config with dependencies passes" do
      assert {:ok, %Config{}, _warnings} = Validator.validate(multi_team_config())
    end

    test "empty name is an error" do
      config = %{valid_config() | name: ""}
      assert {:error, errors} = Validator.validate(config)
      assert "name cannot be empty" in errors
    end

    test "whitespace-only name is an error" do
      config = %{valid_config() | name: "   "}
      assert {:error, errors} = Validator.validate(config)
      assert "name cannot be empty" in errors
    end

    test "empty teams list is an error" do
      config = %{valid_config() | teams: []}
      assert {:error, errors} = Validator.validate(config)
      assert "teams list cannot be empty" in errors
    end

    test "duplicate team names is an error" do
      team = hd(valid_config().teams)
      config = %{valid_config() | teams: [team, team]}
      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "duplicate team names"))
    end

    test "team with empty lead role is an error" do
      config =
        update_first_team(valid_config(), fn team ->
          %{team | lead: %Lead{role: ""}}
        end)

      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "lead must have a non-empty role"))
    end

    test "team with whitespace-only lead role is an error" do
      config =
        update_first_team(valid_config(), fn team ->
          %{team | lead: %Lead{role: "   "}}
        end)

      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "lead must have a non-empty role"))
    end

    test "team with no tasks is an error" do
      config =
        update_first_team(valid_config(), fn team ->
          %{team | tasks: []}
        end)

      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "must have at least one task"))
    end

    test "team with empty task summary is an error" do
      config =
        update_first_team(valid_config(), fn team ->
          %{team | tasks: [%Task{summary: ""}]}
        end)

      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "empty summary"))
    end

    test "team with whitespace-only task summary is an error" do
      config =
        update_first_team(valid_config(), fn team ->
          %{team | tasks: [%Task{summary: "   "}]}
        end)

      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "empty summary"))
    end

    test "dangling depends_on reference is an error" do
      config =
        update_first_team(valid_config(), fn team ->
          %{team | depends_on: ["nonexistent"]}
        end)

      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "depends on unknown teams"))
    end

    test "self-reference in depends_on is an error" do
      config =
        update_first_team(valid_config(), fn team ->
          %{team | depends_on: ["backend"]}
        end)

      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "self-reference"))
    end

    test "dependency cycle between two teams is an error" do
      config = %Config{
        name: "cycle-test",
        defaults: %Defaults{},
        teams: [
          %Team{
            name: "a",
            lead: %Lead{role: "Lead A"},
            tasks: [%Task{summary: "Task A", details: "d", verify: "v"}],
            depends_on: ["b"]
          },
          %Team{
            name: "b",
            lead: %Lead{role: "Lead B"},
            tasks: [%Task{summary: "Task B", details: "d", verify: "v"}],
            depends_on: ["a"]
          }
        ]
      }

      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "cycle"))
    end

    test "dependency cycle among three teams is an error" do
      config = %Config{
        name: "tri-cycle",
        defaults: %Defaults{},
        teams: [
          %Team{
            name: "a",
            lead: %Lead{role: "Lead A"},
            tasks: [%Task{summary: "Task A", details: "d", verify: "v"}],
            depends_on: ["c"]
          },
          %Team{
            name: "b",
            lead: %Lead{role: "Lead B"},
            tasks: [%Task{summary: "Task B", details: "d", verify: "v"}],
            depends_on: ["a"]
          },
          %Team{
            name: "c",
            lead: %Lead{role: "Lead C"},
            tasks: [%Task{summary: "Task C", details: "d", verify: "v"}],
            depends_on: ["b"]
          }
        ]
      }

      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "cycle"))
    end

    test "multiple errors are collected" do
      config = %Config{
        name: "",
        defaults: %Defaults{},
        teams: []
      }

      assert {:error, errors} = Validator.validate(config)
      assert "name cannot be empty" in errors
      assert "teams list cannot be empty" in errors
      assert length(errors) >= 2
    end

    test "valid provider values pass" do
      for provider <- [:cli] do
        config = %{valid_config() | defaults: %Defaults{provider: provider}}
        assert {:ok, %Config{}, _warnings} = Validator.validate(config)
      end
    end

    test "unimplemented provider values are errors" do
      for provider <- [:http] do
        config = %{valid_config() | defaults: %Defaults{provider: provider}}
        assert {:error, errors} = Validator.validate(config)
        assert Enum.any?(errors, &String.contains?(&1, "not yet implemented"))
      end
    end

    test "invalid provider value is an error" do
      config = %{valid_config() | defaults: %Defaults{provider: :openai}}
      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "invalid provider"))
    end

    test "valid backend values pass" do
      for backend <- [:local, :docker, :k8s] do
        config = %{valid_config() | defaults: %Defaults{backend: backend}}
        assert {:ok, %Config{}, _warnings} = Validator.validate(config)
      end
    end

    test "invalid backend value is an error" do
      config = %{valid_config() | defaults: %Defaults{backend: :fly}}
      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "invalid backend"))
    end

    test "provider :external is blocked" do
      config = %{valid_config() | defaults: %Defaults{provider: :external}}
      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "not yet available"))
    end

    test "team-level invalid provider is an error" do
      config =
        update_first_team(valid_config(), fn team ->
          %{team | provider: :openai}
        end)

      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "invalid provider"))
    end

    test "team-level invalid backend is an error" do
      config =
        update_first_team(valid_config(), fn team ->
          %{team | backend: :fly}
        end)

      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "invalid backend"))
    end

    test "team-level provider :external is blocked" do
      config =
        update_first_team(valid_config(), fn team ->
          %{team | provider: :external}
        end)

      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "not yet available"))
    end

    test "provider :http is blocked until Provider.HTTP ships" do
      config = %{valid_config() | defaults: %Defaults{provider: :http}}
      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "not yet implemented"))
    end

    test "team-level provider :http is blocked" do
      config =
        update_first_team(valid_config(), fn team ->
          %{team | provider: :http}
        end)

      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "not yet implemented"))
    end

    test "nil team-level provider and backend pass (inherit from defaults)" do
      config =
        update_first_team(valid_config(), fn team ->
          %{team | provider: nil, backend: nil}
        end)

      assert {:ok, %Config{}, _warnings} = Validator.validate(config)
    end
  end

  # --- Soft Warning Tests ---

  describe "validate/1 — soft warnings" do
    test "team with more than 5 members produces a warning" do
      members = for i <- 1..6, do: %Member{role: "Member #{i}"}

      config =
        update_first_team(valid_config(), fn team ->
          %{team | members: members}
        end)

      assert {:ok, _config, warnings} = Validator.validate(config)
      assert Enum.any?(warnings, &String.contains?(&1, "6 members"))
    end

    test "team with exactly 5 members produces no warning" do
      members = for i <- 1..5, do: %Member{role: "Member #{i}"}

      config =
        update_first_team(valid_config(), fn team ->
          %{team | members: members}
        end)

      assert {:ok, _config, warnings} = Validator.validate(config)
      refute Enum.any?(warnings, &String.contains?(&1, "members"))
    end

    test "task with nil details produces a warning" do
      config =
        update_first_team(valid_config(), fn team ->
          %{team | tasks: [%Task{summary: "Work", verify: "echo ok"}]}
        end)

      assert {:ok, _config, warnings} = Validator.validate(config)
      assert Enum.any?(warnings, &String.contains?(&1, "empty details"))
    end

    test "task with empty string details produces a warning" do
      config =
        update_first_team(valid_config(), fn team ->
          %{team | tasks: [%Task{summary: "Work", details: "", verify: "echo ok"}]}
        end)

      assert {:ok, _config, warnings} = Validator.validate(config)
      assert Enum.any?(warnings, &String.contains?(&1, "empty details"))
    end

    test "task with nil verify produces a warning" do
      config =
        update_first_team(valid_config(), fn team ->
          %{team | tasks: [%Task{summary: "Work", details: "Some details"}]}
        end)

      assert {:ok, _config, warnings} = Validator.validate(config)
      assert Enum.any?(warnings, &String.contains?(&1, "empty verify"))
    end

    test "task with empty string verify produces a warning" do
      config =
        update_first_team(valid_config(), fn team ->
          %{team | tasks: [%Task{summary: "Work", details: "Details", verify: ""}]}
        end)

      assert {:ok, _config, warnings} = Validator.validate(config)
      assert Enum.any?(warnings, &String.contains?(&1, "empty verify"))
    end

    test "fully specified task produces no warnings" do
      config =
        update_first_team(valid_config(), fn team ->
          %{
            team
            | tasks: [%Task{summary: "Work", details: "Do it", verify: "make test"}],
              members: []
          }
        end)

      assert {:ok, _config, warnings} = Validator.validate(config)
      assert warnings == []
    end

    test "backend :docker with provider :cli produces a warning" do
      config = %{valid_config() | defaults: %Defaults{provider: :cli, backend: :docker}}

      config =
        update_first_team(config, fn team ->
          %{team | tasks: [%Task{summary: "Work", details: "Do it", verify: "make test"}]}
        end)

      assert {:ok, _config, warnings} = Validator.validate(config)
      assert Enum.any?(warnings, &String.contains?(&1, "unusual"))
    end

    test "backend :k8s with provider :cli produces a warning" do
      config = %{valid_config() | defaults: %Defaults{provider: :cli, backend: :k8s}}

      config =
        update_first_team(config, fn team ->
          %{team | tasks: [%Task{summary: "Work", details: "Do it", verify: "make test"}]}
        end)

      assert {:ok, _config, warnings} = Validator.validate(config)
      assert Enum.any?(warnings, &String.contains?(&1, "unusual"))
    end

    test "backend :local with provider :cli produces no provider/backend warning" do
      config =
        update_first_team(valid_config(), fn team ->
          %{
            team
            | tasks: [%Task{summary: "Work", details: "Do it", verify: "make test"}],
              members: []
          }
        end)

      assert {:ok, _config, warnings} = Validator.validate(config)
      refute Enum.any?(warnings, &String.contains?(&1, "unusual"))
    end

    test "team-level backend :docker with inherited :cli provider produces a warning" do
      config =
        update_first_team(valid_config(), fn team ->
          %{
            team
            | backend: :docker,
              tasks: [%Task{summary: "Work", details: "Do it", verify: "make test"}]
          }
        end)

      assert {:ok, _config, warnings} = Validator.validate(config)
      assert Enum.any?(warnings, &String.contains?(&1, "unusual"))
    end
  end

  # --- Helpers ---

  defp update_first_team(%Config{teams: [team | rest]} = config, fun) do
    %{config | teams: [fun.(team) | rest]}
  end
end
