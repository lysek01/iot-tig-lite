# Adds tags from the levels of the "topic" tag (MQTT_TOPIC_TAGS).
#
# patterns (constant): comma separated patterns like "_/_/_/node/meas".
# A pattern applies to topics with the same number of levels; "_" skips a level.
# Used for data from MQTT and from the HTTP input alike.

def apply(metric):
    topic = metric.tags.get("topic")
    if topic == None:
        return metric
    levels = topic.split("/")
    for p in patterns.split(","):
        names = p.strip().split("/")
        if len(names) != len(levels):
            continue
        for i in range(len(names)):
            if names[i] != "_" and levels[i] != "":
                metric.tags[names[i]] = levels[i]
        break
    return metric
