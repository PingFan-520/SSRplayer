#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_td_prj.py —— 生成 TD（Anlogic）工程文件 prj/yuanshen_hdmi.al

工程文件是 XML，手写容易漏文件；这里按固定顺序扫描 rtl/ 下的源文件，
约束用 constraints/board.adc + constraints/board.sdc，顶层 top_board。

用法：
    python tools/gen_td_prj.py
"""

import os
import io

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRJ_DIR = os.path.join(ROOT, "prj")
PRJ_NAME = "yuanshen_hdmi"

# 编译顺序：底层/工具模块 -> 视频 -> UI -> 顶层
SOURCES = [
    "rtl/common/seg7.v",
    "rtl/video/color_bar_hd.v",
    "rtl/video/test_pattern_b.v",
    "rtl/video/rgb2axis.v",
    "rtl/video/bmp_decode.v",
    "rtl/ui/font_rom.v",
    "rtl/ui/key_ctrl.v",
    "rtl/ui/alpha_blend.v",
    "rtl/ui/transition.v",
    "rtl/ui/param_apply.v",
    "rtl/ui/cfg_latch.v",
    "rtl/ui/osd_menu.v",
    "rtl/top_osd_demo.v",
    "rtl/hdmi/lane_lvds_10_1.v",
    "rtl/hdmi/hdmi_phy_warpper.v",
    "rtl/hdmi/hdmi_1_4b_transmitter_core_wrapper.enc.v",
    "rtl/top_board.v",
]

ADC = "constraints/board.adc"
SDC = "constraints/board.sdc"

TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<Project Version="3" Minor="2" Path="{path}">
    <Project_Created_Time></Project_Created_Time>
    <TD_Version>6.2.168116</TD_Version>
    <Name>{name}</Name>
    <HardWare>
        <Family>EG4</Family>
        <Device>EG4S20BG256</Device>
        <Speed></Speed>
    </HardWare>
    <Source_Files>
        <Verilog>
{sources}        </Verilog>
        <ADC_FILE>
            <File Path="../{adc}">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&amp;R" Val="true"/>
                    <Attr Name="BelongTo" Val="constraint_1"/>
                    <Attr Name="CompileOrder" Val="1"/>
                </FileInfo>
            </File>
        </ADC_FILE>
        <SDC_FILE>
            <File Path="../{sdc}">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&amp;R" Val="true"/>
                    <Attr Name="BelongTo" Val="constraint_1"/>
                    <Attr Name="CompileOrder" Val="2"/>
                </FileInfo>
            </File>
        </SDC_FILE>
    </Source_Files>
    <FileSets>
        <FileSet Name="design_1" Type="DesignFiles">
        </FileSet>
        <FileSet Name="constraint_1" Type="ConstrainFiles">
        </FileSet>
    </FileSets>
    <TOP_MODULE>
        <LABEL>top_board</LABEL>
        <MODULE>top_board</MODULE>
        <CREATEINDEX>user</CREATEINDEX>
    </TOP_MODULE>
    <Property>
    </Property>
    <Device_Settings>
    </Device_Settings>
    <Configurations>
    </Configurations>
    <Runs>
        <Run Name="syn_1" Type="Synthesis" ConstraintSet="constraint_1" Description="" Active="true">
            <Strategy Name="Default_Synthesis_Strategy">
            </Strategy>
            <UserParams>
            </UserParams>
        </Run>
        <Run Name="phy_1" Type="PhysicalDesign" ConstraintSet="constraint_1" Description="" SynRun="syn_1" Active="true">
            <Strategy Name="Default_PhysicalDesign_Strategy">
            </Strategy>
            <UserParams>
            </UserParams>
        </Run>
    </Runs>
    <Project_Settings>
    </Project_Settings>
</Project>
"""

FILE_TMPL = """            <File Path="../{rel}">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&amp;R" Val="true"/>
                    <Attr Name="BelongTo" Val="design_1"/>
                    <Attr Name="CompileOrder" Val="{order}"/>
                </FileInfo>
            </File>
"""


def main():
    missing = [s for s in SOURCES if not os.path.isfile(os.path.join(ROOT, s))]
    if missing:
        raise SystemExit("缺少源文件：\n  " + "\n  ".join(missing))

    blocks = []
    for i, rel in enumerate(SOURCES, 1):
        blocks.append(FILE_TMPL.format(rel=rel.replace("\\", "/"), order=i))

    text = TEMPLATE.format(
        path=PRJ_DIR.replace("\\", "/"),
        name=PRJ_NAME,
        sources="".join(blocks),
        adc=ADC,
        sdc=SDC,
    )

    os.makedirs(PRJ_DIR, exist_ok=True)
    out = os.path.join(PRJ_DIR, PRJ_NAME + ".al")
    io.open(out, "w", encoding="utf-8", newline="\n").write(text)
    print("written:", out)
    print("sources:", len(SOURCES))


if __name__ == "__main__":
    main()
