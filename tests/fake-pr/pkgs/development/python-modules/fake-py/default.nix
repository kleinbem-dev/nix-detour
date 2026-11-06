{
  python,
  toPythonModule,
  writeTextDir,
  fake-lib,
}:
toPythonModule (
  (writeTextDir "share/fake-py" "${python.pythonVersion} ${fake-lib}") // { version = "1.0"; }
)
