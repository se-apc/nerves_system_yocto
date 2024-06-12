defmodule Nerves.System.Yocto do
  use Nerves.Package.Platform

  alias Nerves.Artifact

  import Mix.Nerves.Utils

  @doc """
  Called as the last step of bootstrapping the Nerves env.
  """
  def bootstrap(_pkg = %{path: path}) do
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
    else
       IO.puts("sdk_sh = #{inspect sdk_sh} does not exist! We shall attempt at the later stage...")
    end
  end

  @doc """
  Build the artifact
  """
  def build(pkg, toolchain, opts) do
    Mix.shell().info("Build...")

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
    deploy_dir = pkg.config[:platform_config][:deploy_dir]
    image = pkg.config[:platform_config][:image]
    machine = pkg.config[:platform_config][:machine]
    sdk_image = pkg.config[:platform_config][:sdk_image] || pkg.config[:platform_config][:image]
    package_dir = package_dir(pkg)

    Mix.shell().info("Make...")
    Mix.shell().info("    package_dir = #{package_dir}")
    Mix.shell().info("    deploy_dir   = #{deploy_dir}")

   #  File.cp
    if setup do
      bash(setup, cd: pkg.path)
    end

    File.rm_rf(package_dir)

    nerves_system_yocto_path =
      Nerves.Env.package(:nerves_system_yocto)
      |> Map.get(:path)

    Mix.shell().info("Building")

    with :ok <- ensure_image(pkg),
         :ok <- ensure_sdk(pkg),
         {_, 0} <-
           bash(
             "./#{deploy_dir}/sdk/#{sdk_image} -y -d #{package_dir}/toolchain",
             cd: pkg.path
           ) do
      bash("mv #{package_dir}/toolchain/staging #{package_dir}/staging", cd: pkg.path)

      File.mkdir_p("#{package_dir}/config/")
      File.mkdir_p("#{package_dir}/scripts/")

      bash(
        "ln -fs `pwd`/#{deploy_dir}/images/#{machine} #{package_dir}/images",
        cd: pkg.path
      )

      bash(
        "ln -fs #{image}-#{machine}.squashfs rootfs.squashfs",
        cd: Path.join(package_dir(pkg), "images")
      )

      # Layer the config/scripts directories
      for source <- [nerves_system_yocto_path, pkg.path],
          conf_dir <- ~w(config scripts),
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

  # KAS_BUILD_DIR=build-nmc4/ kas build kas/meta-nmc4/nmc4-dev.yml -c populate_sdk --target agilis-core-image-dev
  def bitbake(pkg, command) do
    build_dir = pkg.config[:platform_config][:build_dir]
    poky_dir = pkg.config[:platform_config][:poky_dir]
    yml_file = pkg.config[:platform_config][:yml_file]

    full_cmd = "kas build #{yml_file} #{command}"
    Mix.shell().info("KAS_BUILD_DIR=#{build_dir} #{full_cmd}")
    bash(full_cmd, cd: pkg.path, env: [{"KAS_BUILD_DIR", build_dir}])
  end

  def ensure_image(pkg) do
    build_dir = pkg.config[:platform_config][:build_dir]
    image = pkg.config[:platform_config][:image]
    machine = pkg.config[:platform_config][:machine]

    squashfs_file = "#{build_dir}/tmp/deploy/images/#{machine}/#{image}-#{machine}.squashfs"

    unless File.exists?(squashfs_file) do
      Mix.shell().info("#{squashfs_file} does not exist, rebuilding...")
      bitbake(pkg, "#{image}")
    end

    :ok
  end

  def ensure_sdk(pkg) do
    build_dir = pkg.config[:platform_config][:build_dir]
    sdk_image = pkg.config[:platform_config][:sdk_image]

    unless Path.wildcard("#{build_dir}/tmp/deploy/sdk/poky-*-#{sdk_image}-*.sh") do
      bitbake(pkg, "-c populate_sdk #{sdk_image}")
    end

    :ok
  end

  # Translates the given list of sclusions into the parameters' string that can be passed to tar ‘--exclude=pattern’
  defp exclude_tar_params(nil) do
    ""
  end
  defp exclude_tar_params(list) do
    for elem <- list do
	"--exclude=\'#{elem}\'"
    end
    |> Enum.join(" ")
  end

  defp sdk_file(pkg) do
    deploy_dir = pkg.config[:platform_config][:deploy_dir]
    sdk_image = pkg.config[:platform_config][:sdk_image] || pkg.config[:platform_config][:image]
    "#{pkg.path}/#{deploy_dir}/sdk/#{sdk_image}"
  end

  defp make_archive(:linux, pkg, toolchain, opts) do
    package_dir = package_dir(pkg)
    deploy_dir = pkg.config[:platform_config][:deploy_dir]
    sdk_image = pkg.config[:platform_config][:sdk_image] || pkg.config[:platform_config][:image]

    # Work-around the need of changing VERSION in order to have the nerves_system_yocto built
    # In the worst case we shall invoke make function twice and that has negligible overhead.
    #make(:linux, pkg, toolchain, opts)

    # Delete toolchain
    File.rm_rf!("#{pkg.path}/#{package_dir}/toolchain")
    bash("[ -d #{package_dir}/images ] && rm -rfv #{package_dir}/images", cd: pkg.path)

    # Create directory
    File.mkdir_p!("#{pkg.path}/#{package_dir}")

    # Copy SDK
    Mix.shell().info("Copying SDK to #{package_dir}/poky.sh")

    File.cp!(sdk_file(pkg), "#{pkg.path}/#{package_dir}/poky.sh")

    #bash("cp -Rf #{build_dir}/tmp/deploy/images/#{machine} #{package_dir}/images", cd: pkg.path)

    name = Artifact.download_name(pkg)

    # {:ok, pid} = Nerves.Utils.Stream.start_link(file: "archive.log")
    # stream = IO.stream(pid, :line)

    package_path = Path.join(Mix.Project.build_path(), name <> Artifact.ext(pkg))

    exclusion_list = pkg.config[:platform_config][:exclude]
    exclude_params = exclude_tar_params(exclusion_list)

    bash(
      "tar c -z -f #{package_path} -C #{Mix.Project.build_path()} #{exclude_params} #{Artifact.name(pkg)}",
      cd: pkg.path
    )

    # The package_dir has been heavily modified.  Remove it so
    # it can be rebuilt correctly
    package_dir = package_dir(pkg)
    File.rm_rf!(package_dir)

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
