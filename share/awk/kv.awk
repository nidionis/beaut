# kv.awk - print key<TAB>value for each key=value line.
#
# The split happens at the first "=" only, so values may contain more of them.
# Set KV_KEY in the environment to print a single key.
{
  i = index($0, "=")
  if (i > 1) {
    key = substr($0, 1, i - 1)
    if (ENVIRON["KV_KEY"] == "" || key == ENVIRON["KV_KEY"])
      print key "\t" substr($0, i + 1)
  }
}
