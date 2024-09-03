#define VERSION_base "4.5.0.0"
#define MIN_VERSION_base(major1,major2,minor) (\
  (major1) <  4 || \
  (major1) == 4 && (major2) <  5 || \
  (major1) == 4 && (major2) == 5 && (minor) <= 0)
