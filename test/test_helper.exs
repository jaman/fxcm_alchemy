Application.put_env(
  :fix_alchemy,
  :generated_dir,
  Path.join(System.tmp_dir!(), "fxcm_alchemy_generated_test")
)

ExUnit.start()
