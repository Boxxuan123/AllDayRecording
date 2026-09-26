"""供 DevEco Testing Hypium PyCharm 插件生成单用例回归测试包。"""

from setuptools import setup


setup(
    name="alldayrecording-phone-ui-smoke",
    version="1.0.0.0",
    py_modules=["testcases.PhoneMoreSmoke"],
    include_package_data=True,
)
