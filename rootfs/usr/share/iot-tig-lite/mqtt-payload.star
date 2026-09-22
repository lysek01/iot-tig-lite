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

load("json.star", "json")
load("logging.star", "log")

MAX_ITEMS = 500

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

    fields = {}
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
                flatten(obj, fields)
        if len(fields) == 0 and mode == "auto":
            fields["text"] = s

    if len(fields) == 0:
        log.warn("topic '%s': payload %r does not match MQTT_FORMAT=%s, message dropped" % (topic, s[:80], mode))
        return None

    metric.fields.clear()
    for k, v in fields.items():
        metric.fields[k] = v
    return metric
