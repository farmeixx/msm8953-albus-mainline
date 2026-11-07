p = "lk2nd-src/lk2nd/device/dts/msm8953/rules.mk"
s = open(p).read()
old = "\t$(LOCAL_DIR)/msm8953-motorola-potter.dtb \\"
new = "\t$(LOCAL_DIR)/msm8953-motorola-albus.dtb \\\n" + old
assert old in s, "rules.mk anchor not found"
open(p, "w").write(s.replace(old, new, 1))
print("rules.mk patched: albus added to QCDTBS")
