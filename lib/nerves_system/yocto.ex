defmodule Nerves.System.Yocto do
  use Nerves.Package.Platform

  alias Nerves.Artifact

  import Mix.Nerves.Utils

  @doc """
  Called as the last step of bootstrapping the Nerves env.
  """
  def bootstrap(pkg = %{path: path}) do
    path
    |> Path.join("nerves_env.exs")
    |> Code.require_file()
  end

  def ensure_unpacked(path) do
    sdk_sh = Path.join(path, "poky.sh")

    if File.exists?(sdk_sh) do
      Mix.shell().info("Unpacking ...")
      bash("./poky.sh -y -d toolchain", cd: path)
      bash("mv toolchain/staging staging", cd: path)

      File.rm(sdk_sh)
    end
  end

  @doc """
  Build the artifact
  """
  def build(pkg, toolchain, opts) do
    {_, type} = :os.type()
    make(type, pkg, toolchain, opts)
  end

  @doc """
  Return the location in the build path to where the global artifact is linked.
  """
  def build_path_link(pkg) do
    Artifact.build_path(pkg)
  end

  @doc """
  Clean up all the build files
  """
  def clean(pkg) do
    Artifact.Cache.delete(pkg)

    build_dir = pkg.config[:platform_config][:build_dir]

    # Artifact.build_path(pkg)
    # |> File.rm_rf()

    Nerves.Env.package(pkg)
    |> Map.get(:path)
    |> Path.join(build_dir)
    |> Path.join("tmp")
    |> File.rm_rf()
  end

  @doc """
  Create an archive of the artifact
  """
  def archive(pkg, toolchain, opts) do
    {_, type} = :os.type()
    make_archive(type, pkg, toolchain, opts)
  end

  defp make(:linux, pkg, _toolchain, _opts) do
    setup = pkg.config[:platform_config][:setup]
    build_dir = pkg.config[:platform_config][:build_dir]
    image = pkg.config[:platform_config][:image]
    machine = pkg.config[:platform_config][:machine]
    sdk_image = pkg.config[:platform_config][:sdk_image] || pkg.config[:platform_config][:image]

    if setup do
      bash(setup, cd: pkg.path)
    end

    package_dir = package_dir(pkg)
    File.rm_rf(package_dir)

    nerves_system_yocto_path =
      Nerves.Env.package(:nerves_system_yocto)
      |> Map.get(:path)

    Mix.shell().info("Building")

    with :ok <- ensure_image(pkg),
         :ok <- ensure_sdk(pkg),
         {_, 0} <-
           bash(
             "./#{build_dir}/tmp/deploy/sdk/poky-*-#{sdk_image}-*.sh -y -d #{package_dir}/toolchain",
             cd: pkg.path
           ) do
      bash("mv #{package_dir}/toolchain/staging #{package_dir}/staging", cd: pkg.path)

      File.mkdir_p("#{package_dir}/config/")
      File.mkdir_p("#{package_dir}/scripts/")

      bash(
        "ln -fs `pwd`/#{build_dir}/tmp/deploy/images/#{machine} #{package_dir}/images",
        cd: pkg.path
      )

      bash(
        "ln -fs #{image}-#{machine}.squashfs rootfs.squashfs",
        cd: Path.join(package_dir(pkg), "images")
      )

      # Layer the config/scripts directories
      for source <- [nerves_system_yocto_path, pkg.path],
          conf_dir <- ~w(config, scripts),
          File.exists?(Path.join(source, conf_dir)) do
        bash(
          "cp -r #{nerves_system_yocto_path}/#{conf_dir}/* #{package_dir}/#{conf_dir}/",
          cd: pkg.path
        )
      end

      # Make sure the scripts are executable
      bash(
        "chmod +x #{package_dir}/scripts/*",
        cd: pkg.path
      )

      {:ok, package_dir}
    else
      _ -> {:error, "Compile failed"}
    end
  end

  defp make(type, _pkg, _toolchain, _opts) do
    error_host_os(type)
  end

  def bitbake(pkg, command) do
    build_dir = pkg.config[:platform_config][:build_dir]
    poky_dir = pkg.config[:platform_config][:poky_dir]

    oe_init_build = "#{poky_dir}/oe-init-build-env"
    Mix.shell().info("bitbake #{command}")
    bash("source #{oe_init_build} #{build_dir} && bitbake #{command}", cd: pkg.path)
  end

  def ensure_image(pkg) do
    build_dir = pkg.config[:platform_config][:build_dir]
    image = pkg.config[:platform_config][:image]
    machine = pkg.config[:platform_config][:machine]

    unless File.exists?("#{build_dir}/tmp/deploy/images/#{machine}/#{image}-#{machine}.squashfs") do
      bitbake(pkg, "#{image}")
    end

    :ok
  end

  def ensure_sdk(pkg) do
    build_dir = pkg.config[:platform_config][:build_dir]
    sdk_image = pkg.config[:platform_config][:sdk_image] || pkg.config[:platform_config][:image]

    unless Path.wildcard("#{build_dir}/tmp/deploy/sdk/poky-*-#{sdk_image}-*.sh") do
      bitbake(pkg, "-c populate_sdk #{sdk_image}")
    end

    :ok
  end

  defp make_archive(:linux, pkg, _toolchain, _opts) do
    package_dir = package_dir(pkg)
    machine = pkg.config[:platform_config][:machine]
    build_dir = pkg.config[:platform_config][:build_dir]
    sdk_image = pkg.config[:platform_config][:sdk_image] || pkg.config[:platform_config][:image]

    # Delete toolchain
    bash("rm -Rf #{package_dir}/toolchain", cd: pkg.path)
    bash("[ -d #{package_dir}/images ] && rm -rfv #{package_dir}/images", cd: pkg.path)

    # Create directory
    bash(
      "mkdir -p #{package_dir}",
      cd: pkg.path
    )

    # Copy SDK
    bash(
      "cp ./#{build_dir}/tmp/deploy/sdk/poky-*-#{sdk_image}-*.sh #{package_dir}/poky.sh",
      cd: pkg.path
    )

    bash("cp -Rf #{build_dir}/tmp/deploy/images/#{machine} #{package_dir}/images", cd: pkg.path)

    name = Artifact.download_name(pkg)

    # {:ok, pid} = Nerves.Utils.Stream.start_link(file: "archive.log")
    # stream = IO.stream(pid, :line)

    package_path = Path.join(Mix.Project.build_path(), name <> Artifact.ext(pkg))

    bash(
      "tar c -z -f #{package_path} -C #{Mix.Project.build_path()} #{Artifact.name(pkg)}",
      cd: pkg.path
    )

    # The package_dir has been heavily modified.  Remove it so
    # it can be rebuilt correctly
    package_dir = package_dir(pkg)
    File.rm_rf(package_dir)

    if File.exists?(package_path) do
      {:ok, package_path}
    else
      {:error, "Package #{package_path} not found"}
    end
  end

  defp make_archive(type, _pkg, _toolchain, _opts) do
    error_host_os(type)
  end

  defp error_host_os(type) do
    {:error,
     """
     Local build_runner is not available for host system: #{type}
     Please use the Docker build_runner to build this package artifact
     """}
  end

  def package_dir(pkg) do
    Mix.Project.build_path()
    |> Path.join(Artifact.name(pkg))
  end

  defp bash(command, opts) do
    bash = System.find_executable("bash")
    shell(bash, ["-O", "extglob", "-c", command], opts)
  end
end
