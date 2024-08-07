defmodule EMQXRuleEngine.MixProject do
  use Mix.Project
  alias EMQXUmbrella.MixProject, as: UMP

  def project do
    [
      app: :emqx_rule_engine,
      version: "0.1.0",
      build_path: "../../_build",
      erlc_options: UMP.erlc_options(),
      erlc_paths: UMP.erlc_paths(),
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: UMP.extra_applications(), mod: {:emqx_rule_engine_app, []}]
  end

  def deps() do
    UMP.jq_dep() ++ [
      {:emqx, in_umbrella: true},
      {:emqx_ctl, in_umbrella: true},
      {:emqx_utils, in_umbrella: true},
      {:emqx_modules, in_umbrella: true},
      {:emqx_resource, in_umbrella: true},
      {:emqx_bridge, in_umbrella: true},
      UMP.common_dep(:rulesql),
      UMP.common_dep(:emqtt),
      UMP.common_dep(:uuid),
    ]
  end
end
