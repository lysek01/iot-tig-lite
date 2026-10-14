# Converts the raw MQTT payload (field "value", string) into fields.
#
# mode (constant from Telegraf config):
#   auto  - number / true / false -> field "value" (float)
#           JSON                  -> one field per key, nested keys joined by "_"
#           anything else         -> field "text" (string)
#   value - number / true / false -> field "value", anything else is dropped
#   json  - JSON only, anything else is dropped
#
# All numbers are stored as float so a field never changes its type
# (InfluxDB rejects "23" after "23.5" when types differ).
#
# time_field (constant): name of a top-level JSON key holding the time of the
# measurement. Empty = time of reception. Accepted values:
#   ISO 8601 / RFC 3339   "2026-10-14T12:00:00.123+02:00", "...Z",
#                         without offset -> local time in tz (constant)
#   Unix time             seconds, ms, us or ns (number or numeric string)

load("json.star", "json")
load("logging.star", "log")
load("time.star", "time")

MAX_ITEMS = 500
DIGITS = "0123456789"

def epoch_ns(x):
    # guess the unit from the size of the number
    if x > 1e17:
        return int(x)
    if x > 1e14:
        return int(x * 1e3)
    if x > 1e11:
        return int(x * 1e6)
    if x > 1e8:
        return int(x * 1e9)
    return None

def iso_shape(s):
    # YYYY-MM-DDThh:mm:ss[.fff][Z|+hh:mm|-hh:mm]; returns "tz", "local" or None
    if len(s) < 19:
        return None
    for i in range(19):
        c = s[i]
        if i in (4, 7):
            ok = c == "-"
        elif i == 10:
            ok = c == "T"
        elif i in (13, 16):
            ok = c == ":"
        else:
            ok = c in DIGITS
        if not ok:
            return None
    rest = s[19:]
    if rest.startswith("."):
        n = 1
        for i in range(1, len(rest)):
            if rest[i] not in DIGITS:
                break
            n = i + 1
        if n == 1:
            return None
        rest = rest[n:]
    if rest == "":
        return "local"
    if rest == "Z":
        return "tz"
    if len(rest) == 6 and rest[0] in "+-" and rest[3] == ":" and rest[1] in DIGITS and rest[2] in DIGITS and rest[4] in DIGITS and rest[5] in DIGITS:
        return "tz"
    return None

def parse_time(v):
    # returns Unix time in ns, or None
    t = type(v)
    if t == "int" or t == "float":
        return epoch_ns(float(v))
    if t != "string":
        return None
    s = v.strip()
    num = parse_number(s)
    if num != None:
        return epoch_ns(num)
    if len(s) > 10 and s[10] == " ":
        s = s[:10] + "T" + s[11:]
    shape = iso_shape(s)
    if shape == "tz":
        return time.parse_time(s).unix_nano
    if shape == "local":
        return time.parse_time(s, format = "2006-01-02T15:04:05", location = tz).unix_nano
    return None

def parse_number(s):
    n = len(s)
    if n == 0 or n > 64:
        return None
    start = 0
    if s[0] == "+" or s[0] == "-":
        start = 1
    digits = False
    dot = False
    exp = False
    prev = ""
    for i in range(start, n):
        c = s[i]
        if c.isdigit():
            digits = True
        elif c == "." and not dot and not exp:
            dot = True
        elif (c == "e" or c == "E") and digits and not exp:
            exp = True
            digits = False
        elif (c == "+" or c == "-") and (prev == "e" or prev == "E"):
            pass
        else:
            return None
        prev = c
    if not digits:
        return None
    if s[0] == "+":
        s = s[1:]
    return float(s)

def parse_bool(s):
    l = s.lower()
    if l == "true":
        return 1.0
    if l == "false":
        return 0.0
    return None

def scalar(v):
    # returns a float for numbers, booleans and numeric strings
    t = type(v)
    if t == "bool":
        return 1.0 if v else 0.0
    if t == "int" or t == "float":
        return float(v)
    if t == "string":
        num = parse_number(v.strip())
        if num != None:
            return num
        return v
    return None

def flatten(obj, out):
    stack = [("", obj)]
    for _ in range(MAX_ITEMS):
        if len(stack) == 0:
            break
        key, v = stack.pop()
        t = type(v)
        if t == "dict":
            for k in v:
                stack.append((key + "_" + k if key else k, v[k]))
        elif t == "list":
            for i, item in enumerate(v):
                stack.append((key + "_" + str(i) if key else "value_" + str(i), item))
        else:
            val = scalar(v)
            if val == None:
                continue
            if key == "":
                key = "text" if type(val) == "string" else "value"
            out[key] = val

def apply(metric):
    raw = metric.fields.get("value")
    if type(raw) != "string":
        return metric
    s = raw.strip()
    topic = metric.tags.get("topic", "")
    if topic == "":
        # HTTP request without the "Topic" header
        topic = "http"
        metric.tags["topic"] = topic

    fields = {}
    ts = None
    if s != "":
        if mode == "auto" or mode == "value":
            num = parse_number(s)
            if num == None:
                num = parse_bool(s)
            if num != None:
                fields["value"] = num
        if len(fields) == 0 and (mode == "json" or (mode == "auto" and (s.startswith("{") or s.startswith("[")))):
            obj = json.decode(s, None)   # None = not valid JSON
            if obj != None:
                if time_field and type(obj) == "dict" and time_field in obj:
                    tv = obj.pop(time_field)
                    ts = parse_time(tv)
                    if ts == None:
                        log.warn("topic '%s': %s=%r is not a valid time, time of reception used" % (topic, time_field, tv))
                flatten(obj, fields)
        if len(fields) == 0 and mode == "auto":
            fields["text"] = s

    if len(fields) == 0:
        log.warn("topic '%s': payload %r does not match MQTT_FORMAT=%s, message dropped" % (topic, s[:80], mode))
        return None

    metric.fields.clear()
    for k, v in fields.items():
        metric.fields[k] = v
    if ts != None:
        metric.time = ts
    return metric
