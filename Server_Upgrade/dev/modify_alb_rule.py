import boto3
import argparse
import sys

# ---- Parse CLI arguments ----
parser = argparse.ArgumentParser(description="Update ALB listener rule based on host header")
parser.add_argument("--listener-arn", required=True, help="ARN of the ALB listener (port 443)")
parser.add_argument("--host-header", required=True, help="Host header to match (e.g., demo-arohan.perdix.co)")
parser.add_argument("--target-group-arn", required=True, help="New target group ARN to forward traffic to")

args = parser.parse_args()

listener_arn = args.listener_arn
host_header = args.host_header
new_target_group_arn = args.target_group_arn

client = boto3.client("elbv2", region_name="ap-south-1")

# Step 1: Fetch all rules
try:
    response = client.describe_rules(ListenerArn=listener_arn)
except Exception as e:
    print(f"❌ Error describing rules: {e}")
    sys.exit(1)

rules = response.get("Rules", [])
target_rule = None

# Step 2: Match rule by host-header
for rule in rules:
    for condition in rule.get("Conditions", []):
        if condition["Field"] == "host-header" and host_header in condition.get("Values", []):
            target_rule = rule
            break
    if target_rule:
        break

if not target_rule:
    print(f"❌ No rule found for host header: {host_header}")
    sys.exit(1)

rule_arn = target_rule["RuleArn"]
print(f"✅ Found matching rule: {rule_arn}")

# Step 3: Modify rule to forward to new TG
try:
    client.modify_rule(
        RuleArn=rule_arn,
        Actions=[
            {
                "Type": "forward",
                "TargetGroupArn": new_target_group_arn
            }
        ]
    )
    print(f"✅ Updated rule to use target group: {new_target_group_arn}")
except Exception as e:
    print(f"❌ Failed to update rule: {e}")
    sys.exit(1)
