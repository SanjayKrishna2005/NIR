set xsa_path "nir_system_wrapper.xsa"
set app_name "nir_app"
set platform_name "nir_platform"

platform create -name $platform_name -hw $xsa_path
domain create -name standalone_domain -display-name "standalone on ps7_cortexa9_0" -os standalone -proc ps7_cortexa9_0
platform generate

app create -name $app_name -platform $platform_name -domain standalone_domain -template {Empty Application(C)}

importsources -name $app_name -path "nir_baremetal.c" -target-path src

app build -name $app_name