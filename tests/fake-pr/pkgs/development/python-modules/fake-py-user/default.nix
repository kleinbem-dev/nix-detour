{
  toPythonModule,
  writeTextDir,
  fake-py,
}:
toPythonModule ((writeTextDir "share/fake-py-user" "${fake-py}") // { version = "1.0"; })
