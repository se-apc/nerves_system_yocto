defmodule NervesSystemYocto.Mixfile do
  use Mix.Project

  @version Path.join(__DIR__, "VERSION")
           |> File.read!()
           |> String.trim()

  def project do
    [
      app: :nerves_system_yocto,
      version: @version,
      elixir: "~> 1.3",
      deps: deps(),
      description: description(),
      nerves_package: nerves_package(),
      compilers: Mix.compilers()
    ]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    []
  end

  defp description do
    """
    Nerves System - Yocto
    """
  end

  defp deps do
    [
      {:nerves, github: "se-apc/nerves", runtime: false, override: true}
    ]
  end

  def nerves_package do
    [
      type: :system_platform,
      version: @version
    ]
  end
end
