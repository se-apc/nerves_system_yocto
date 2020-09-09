defmodule System.Env do
  @path "PATH"
  @ld_library_path "LD_LIBRARY_PATH"

  # Hack to map windows path to mingw
  # def path_add("c:/" <> path) do
  #   path_add("/c/" <> path)
  # end

  def path_add(p) do
    case :os.type do
      {:win32, _} ->
        System.put_env(@path, "#{path()};#{p}")
      _ ->
        System.put_env(@path, "#{path()}:#{p}")
    end
  end

  # def ld_library_path_add("c:/"<>p) do
  #   ld_library_path_add("/c/"<>p)
  # end

  def ld_library_path_add(p) do
    case :os.type do
      {:win32, _} ->
        System.put_env(@ld_library_path, "#{ld_library_path()};#{p}")
      _ ->
        System.put_env(@ld_library_path, "#{ld_library_path()}:#{p}")
    end

  end

  def path do
    System.get_env(@path)
  end

  def ld_library_path do
    System.get_env(@ld_library_path)
  end
end

# defmodule Utils do
#   def crosscompile(gcc_path, system_path) do
#     gcc =
#       gcc_path
#       |> Path.join("*gcc")
#       |> Path.wildcard
#       |> List.first

#     gcc || Mix.raise("""
#       gcc should have been found in \"#{gcc_path}\", but wasn't.
#       \"#{system_path}\" is partial or corrupt and may need to be deleted.
#       """)

#     String.replace_suffix(gcc, "-gcc", "")
#   endvi
defmodule Utils do
  def source_shell_env(shell_env) do
    System.cmd("/bin/bash", ["-c", "source #{shell_env}; env -0"])
    |> elem(0)
    |> String.replace("\n","")
    |> String.split("\0")
    |> Enum.map(fn line ->
        case String.split(line,"=", parts: 2) do
          [var_name, value] ->

            old_val = System.get_env(var_name)
            if old_val != value do
              var_name
              |> String.trim()
              |> System.put_env(value)
            else
              :same
            end

          [""] ->
            :single

          [single] ->
            IO.puts "ignoring '#{single}'"
            :single
        end
      end)
  end
end


system_path = System.get_env("NERVES_SYSTEM") ||
  Mix.raise "You must set NERVES_SYSTEM to the system dir prior to requiring this file"

Mix.shell().info("Looking for the poky.sh in #{system_path}")

Nerves.System.Yocto.ensure_unpacked(system_path)
Utils.source_shell_env("#{system_path}/toolchain/environment-setup-nerves.sh")

erl_lib_dir = System.get_env("ERL_DIR")
System.put_env("ERL_LIB_DIR", erl_lib_dir)

erl_system_lib_dir = Path.join(erl_lib_dir, "/lib")
System.put_env("ERL_SYSTEM_LIB_DIR", erl_system_lib_dir)

# toolchain_path =
#   system_path
#   |> Path.join("host")

sdk_sysroot =
  system_path
  |> Path.join("staging")

# yocto_toolchain = "x86_64-pokysdk-linux"

toolchain_path = System.get_env("NERVES_TOOLCHAIN")

crosscompile = System.get_env("CROSSCOMPILE")
# arch_flags = "-march=armv7-a -marm  -mthumb-interwork -mfloat-abi=hard -mtune=cortex-a7 --sysroot=#{sdk_sysroot}"

# TODO:  Bundle these files with sysroots
# System.Env.path_add("/c/dev/bin")

Path.join([toolchain_path, "usr/bin", crosscompile])
|> System.Env.path_add

Path.join(toolchain_path, "usr/bin/squashfs-tools")
|> System.Env.path_add

Path.join(toolchain_path, "usr/bin")
|> System.Env.path_add

Path.join(toolchain_path, "usr/sbin")
|> System.Env.path_add

Path.join(toolchain_path, "bin")
|> System.Env.path_add

Path.join(toolchain_path, "usr/lib")
|> System.Env.ld_library_path_add

Path.join([toolchain_path, "usr/lib",crosscompile])
|> System.Env.ld_library_path_add


if crosscompile == "" do
 Mix.raise "Cannot find a cross compiler"
end

System.put_env("NERVES_SDK_IMAGES", Path.join(system_path, "images"))
System.put_env("NERVES_SDK_SYSROOT", sdk_sysroot)

# system_include_path =
#   sdk_sysroot
#   |> Path.join("usr/include")

# unless File.dir?(Path.join(system_path, "staging")) do
#  Mix.raise "ERROR: It looks like the system hasn't been built!"
# end

erts_dir =
  Path.join(sdk_sysroot, "usr/lib/erlang/erts-*")
  |> Path.wildcard
  |> List.first

System.put_env("ERTS_DIR", erts_dir)

erl_interface_dir =
  Path.join(sdk_sysroot, "usr/lib/erlang/usr")
  |> Path.wildcard
  |> List.first


System.put_env("ERL_INTERFACE_DIR", erl_interface_dir)
rebar_plt_dir =
  Path.join(sdk_sysroot, "/usr/lib/erlang")
System.put_env("REBAR_PLT_DIR", rebar_plt_dir)

# System.put_env("CC", "#{crosscompile}-gcc")
# System.put_env("CXX", "#{crosscompile}-g++")
# System.put_env("CFLAGS", "#{arch_flags} -D_LARGEFILE_SOURCE -D_LARGEFILE64_SOURCE -D_FILE_OFFSET_BITS=64  -pipe -Os -I#{system_include_path} -fno-use-linker-plugin")
# System.put_env("CXXFLAGS", "#{arch_flags} -D_LARGEFILE_SOURCE -D_LARGEFILE64_SOURCE -D_FILE_OFFSET_BITS=64  -pipe -Os -I#{system_include_path} -fno-use-linker-plugin")
# System.put_env("LDFLAGS", "--sysroot=#{sdk_sysroot} -fno-use-linker-plugin")
System.put_env("STRIP", "#{crosscompile}-strip")
System.put_env("ERL_CFLAGS", "-I#{erts_dir}/include -I#{erl_interface_dir}/include")
System.put_env("ERL_LDFLAGS", "-L#{erts_dir}/lib -L#{erl_interface_dir}/lib -lerts -lei")
System.put_env("REBAR_TARGET_ARCH", Path.basename(crosscompile))

# Rebar naming
System.put_env("ERL_EI_LIBDIR", Path.join(erl_interface_dir, "lib"))
System.put_env("ERL_EI_INCLUDE_DIR", Path.join(erl_interface_dir, "include"))

host_erl_major_ver = :erlang.system_info(:otp_release) |> to_string
[target_erl_major_version | _] =
  sdk_sysroot
  |> Path.join("/usr/lib/erlang/releases/*/OTP_VERSION")
  |> Path.wildcard
  |> List.first
  |> File.read!
  |> String.trim
  |> String.split(".")

# Check to see if the system major version of ERL and the target major version match
if host_erl_major_ver != target_erl_major_version do
  Mix.raise """
  Major version mismatch between host and target Erlang/OTP versions
    Host version: #{host_erl_major_ver}
    Target version: #{target_erl_major_version}

  This will likely cause Erlang code compiled for the target to fail in
  unexpected ways. Install an Erlang OTP release that matches the target
  version before continuing.
  """
end
