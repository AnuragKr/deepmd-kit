import logging

import numpy as np

from deepmd.nvnmd.data.data import (
    NVNMD_CITATION,
    NVNMD_WELCOME,
    jdata_config,
    jdata_configs,
    jdata_deepmd_input,
)
from deepmd.nvnmd.utils.fio import (
    FioDic,
)
from deepmd.nvnmd.utils.op import (
    r2s,
)

log = logging.getLogger(__name__)


class NvnmdConfig:
    r"""Configuration for NVNMD
    record the message of model such as size, using nvnmd or not.

    Parameters
    ----------
    jdata
        a dictionary of input script

    References
    ----------
    DOI: 10.1038/s41524-022-00773-z
    """

    def __init__(self, jdata: dict):
        self.map = {}
        self.config = jdata_config
        self.save_path = "nvnmd/config.npy"
        self.weight = {}
        self.init_from_jdata(jdata)

    def init_from_jdata(self, jdata: dict = {}):
        r"""Initial this class with `jdata` loaded from input script."""
        if jdata == {}:
            return None

        self.net_size = jdata["net_size"]
        self.map_file = jdata["map_file"]
        self.config_file = jdata["config_file"]
        self.enable = jdata["enable"]
        self.weight_file = jdata["weight_file"]
        self.restore_descriptor = jdata["restore_descriptor"]
        self.restore_fitting_net = jdata["restore_fitting_net"]
        self.quantize_descriptor = jdata["quantize_descriptor"]
        self.quantize_fitting_net = jdata["quantize_fitting_net"]

        # load data
        if self.enable:
            self.map = FioDic().load(self.map_file, {})
            self.weight = FioDic().load(self.weight_file, {})

            jdata_config_ = jdata_config.copy()
            jdata_config_["fitn"]["neuron"][0] = self.net_size
            load_config = FioDic().load(self.config_file, jdata_config_)
            self.init_from_config(load_config)
            # if load the file, set net_size
            self.init_net_size()

    def init_value(self):
        r"""Initial member with dict."""
        self.dscp = self.config["dscp"]
        self.fitn = self.config["fitn"]
        self.dpin = self.config["dpin"]
        self.size = self.config["size"]
        self.ctrl = self.config["ctrl"]
        self.nbit = self.config["nbit"]

    def update_config(self):
        r"""Update config from dict."""
        self.config["dscp"] = self.dscp
        self.config["fitn"] = self.fitn
        self.config["dpin"] = self.dpin
        self.config["size"] = self.size
        self.config["ctrl"] = self.ctrl
        self.config["nbit"] = self.nbit

    def init_train_mode(self, mod="cnn"):
        r"""Configure for taining cnn or qnn."""
        if mod == "cnn":
            self.restore_descriptor = False
            self.restore_fitting_net = False
            self.quantize_descriptor = False
            self.quantize_fitting_net = False
        elif mod == "qnn":
            self.restore_descriptor = True
            self.restore_fitting_net = True
            self.quantize_descriptor = True
            self.quantize_fitting_net = True

    def init_from_config(self, jdata):
        r"""Initial member element one by one."""
        self.config = FioDic().update(jdata, self.config)
        self.config["dscp"] = self.init_dscp(self.config["dscp"], self.config)
        self.config["fitn"] = self.init_fitn(self.config["fitn"], self.config)
        self.config["dpin"] = self.init_dpin(self.config["dpin"], self.config)
        self.config["size"] = self.init_size(self.config["size"], self.config)
        self.config["ctrl"] = self.init_ctrl(self.config["ctrl"], self.config)
        self.config["nbit"] = self.init_nbit(self.config["nbit"], self.config)
        self.init_value()

    def init_net_size(self):
        r"""Initial net_size."""
        # self.net_size = self.fitn['neuron'][0]
        self.net_size = self.config["fitn"]["neuron"][0]
        if self.enable:
            key = str(self.net_size)
            if key in jdata_configs.keys():
                # log.info(f"NVNMD: configure the net_size is {key}")
                self.init_from_config(jdata_configs[key])
            else:
                log.error("NVNMD: don't have the configure of net_size")

    def init_from_deepmd_input(self, jdata):
        r"""Initial members with input script of deepmd."""
        fioObj = FioDic()
        self.config["dscp"] = fioObj.update(jdata["descriptor"], self.config["dscp"])
        self.config["fitn"] = fioObj.update(jdata["fitting_net"], self.config["fitn"])
        self.config["dscp"] = self.init_dscp(self.config["dscp"], self.config)
        self.config["fitn"] = self.init_fitn(self.config["fitn"], self.config)
        dp_in = {"type_map": fioObj.get(jdata, "type_map", [])}
        self.config["dpin"] = fioObj.update(dp_in, self.config["dpin"])
        #
        self.init_net_size()
        self.init_value()

    def init_dscp(self, jdata: dict, jdata_parent: dict = {}) -> dict:
        r"""Initial members about descriptor."""
        # embedding
        jdata["M1"] = jdata["neuron"][-1]
        jdata["M2"] = jdata["axis_neuron"]
        jdata["SEL"] = (jdata["sel"] + [0, 0, 0, 0])[0:4]
        jdata["NNODE_FEAS"] = [1] + jdata["neuron"]
        jdata["nlayer_fea"] = len(jdata["neuron"])
        jdata["same_net"] = int(1) if jdata["type_one_side"] else int(0)
        # neighbor
        jdata["NIDP"] = int(np.sum(jdata["sel"]))
        jdata["NIX"] = 2 ** int(np.ceil(np.log2(jdata["NIDP"] / 1.5)))
        # type
        jdata["ntype"] = len(jdata["sel"])
        jdata["ntypex"] = 1 if (jdata["same_net"]) else jdata["ntype"]
        return jdata

    def init_fitn(self, jdata: dict, jdata_parent: dict = {}) -> dict:
        r"""Initial members about fitting network."""
        M1 = jdata_parent["dscp"]["M1"]
        M2 = jdata_parent["dscp"]["M2"]

        jdata["NNODE_FITS"] = [int(M1 * M2)] + jdata["neuron"] + [1]
        jdata["nlayer_fit"] = len(jdata["neuron"]) + 1
        jdata["NLAYER"] = jdata["nlayer_fit"]

        return jdata

    def init_dpin(self, jdata: dict, jdata_parent: dict = {}) -> dict:
        r"""initial members about other deepmd input."""
        return jdata

    def init_size(self, jdata: dict, jdata_parent: dict = {}) -> dict:
        r"""Initial members about ram capacity."""
        jdata["NAEXT"] = jdata["Na"]
        jdata["NTYPE"] = jdata_parent["dscp"]["ntype_max"]
        jdata["NTYPEX"] = jdata_parent["dscp"]["ntypex_max"]
        return jdata

    def init_ctrl(self, jdata: dict, jdata_parent: dict = {}) -> dict:
        r"""Initial members about control signal."""
        ntype_max = jdata_parent["dscp"]["ntype_max"]
        jdata["NSADV"] = jdata["NSTDM"] + 1
        jdata["NSEL"] = jdata["NSTDM"] * ntype_max
        if 32 % jdata["NSTDM_M1X"] > 0:
            log.warning(
                "NVNMD: NSTDM_M1X must be divisor of 32 for the right runing in data_merge module"
            )
        return jdata

    def init_nbit(self, jdata: dict, jdata_parent: dict = {}) -> dict:
        r"""Initial members about quantification precision."""
        Na = jdata_parent["size"]["Na"]
        NaX = jdata_parent["size"]["NaX"]
        ntype_max = jdata_parent["dscp"]["ntype_max"]
        NSEL = jdata_parent["ctrl"]["NSEL"]
        # general
        jdata["NBIT_FLTM"] = 1 + jdata["NBIT_FLTF"]
        jdata["NBIT_FLTH"] = 1 + jdata["NBIT_FLTM"]
        # atom
        jdata["NBIT_ENE_FL"] = jdata["NBIT_FIT_DATA_FL"]
        jdata["NBIT_SPE"] = int(np.ceil(np.log2(ntype_max)))
        jdata["NBIT_LST"] = int(np.ceil(np.log2(NaX)))
        jdata["NBIT_CRD3"] = jdata["NBIT_CRD"] * 3
        jdata["NBIT_ATOM"] = jdata["NBIT_SPE"] + jdata["NBIT_CRD3"]
        # middle result
        jdata["NBIT_SEL"] = int(np.ceil(np.log2(NSEL)))
        return jdata

    def save(self, file_name=None):
        r"""Save all configuration to file."""
        if file_name is None:
            file_name = self.save_path
        else:
            self.save_path = file_name
        self.update_config()
        FioDic().save(file_name, self.config)

    def get_s_range(self, davg, dstd):
        rmin = nvnmd_cfg.dscp["rcut_smth"]
        rmax = nvnmd_cfg.dscp["rcut"]
        ntype = self.dscp["ntype"]
        dmin = self.dscp["dmin"]
        #
        s0 = r2s(dmin, rmin, rmax)
        smin_ = -davg[:ntype, 0] / dstd[:ntype, 0]
        smax_ = (s0 - davg[:ntype, 0]) / dstd[:ntype, 0]
        smin = np.min(smin_)
        smax = np.max(smax_)
        self.dscp["smin"] = smin
        self.dscp["smax"] = smax
        nvnmd_cfg.save()
        # check
        log.info(f"the range of s is [{smin}, {smax}]")
        if smax - smin > 16.0:
            log.warning("the range of s is over the limit (smax - smin) > 16.0")
            log.warning(
                "Please reset the rcut_smth as a bigger value to fix this warning"
            )

    def get_dscp_jdata(self):
        r"""Generate `model/descriptor` in input script."""
        dscp = self.dscp
        jdata = jdata_deepmd_input["model"]["descriptor"]
        jdata["sel"] = dscp["sel"]
        jdata["rcut"] = dscp["rcut"]
        jdata["rcut_smth"] = dscp["rcut_smth"]
        jdata["neuron"] = dscp["neuron"]
        jdata["type_one_side"] = dscp["type_one_side"]
        jdata["axis_neuron"] = dscp["axis_neuron"]
        return jdata

    def get_fitn_jdata(self):
        r"""Generate `model/fitting_net` in input script."""
        fitn = self.fitn
        jdata = jdata_deepmd_input["model"]["fitting_net"]
        jdata["neuron"] = fitn["neuron"]
        return jdata

    def get_model_jdata(self):
        r"""Generate `model` in input script."""
        jdata = jdata_deepmd_input["model"]
        jdata["descriptor"] = self.get_dscp_jdata()
        jdata["fitting_net"] = self.get_fitn_jdata()
        if len(self.dpin["type_map"]) > 0:
            jdata["type_map"] = self.dpin["type_map"]
        return jdata

    def get_nvnmd_jdata(self):
        r"""Generate `nvnmd` in input script."""
        jdata = jdata_deepmd_input["nvnmd"]
        jdata["net_size"] = self.net_size
        jdata["config_file"] = self.config_file
        jdata["weight_file"] = self.weight_file
        jdata["map_file"] = self.map_file
        jdata["enable"] = self.enable
        jdata["restore_descriptor"] = self.restore_descriptor
        jdata["restore_fitting_net"] = self.restore_fitting_net
        jdata["quantize_descriptor"] = self.quantize_descriptor
        jdata["quantize_fitting_net"] = self.quantize_fitting_net
        return jdata

    def get_learning_rate_jdata(self):
        r"""Generate `learning_rate` in input script."""
        return jdata_deepmd_input["learning_rate"]

    def get_loss_jdata(self):
        r"""Generate `loss` in input script."""
        return jdata_deepmd_input["loss"]

    def get_training_jdata(self):
        r"""Generate `training` in input script."""
        return jdata_deepmd_input["training"]

    def get_deepmd_jdata(self):
        r"""Generate input script with member element one by one."""
        jdata = jdata_deepmd_input.copy()
        jdata["model"] = self.get_model_jdata()
        jdata["nvnmd"] = self.get_nvnmd_jdata()
        jdata["learning_rate"] = self.get_learning_rate_jdata()
        jdata["loss"] = self.get_loss_jdata()
        jdata["training"] = self.get_training_jdata()
        return jdata

    def disp_message(self):
        r"""Display the log of NVNMD."""
        NVNMD_CONFIG = (
            f"enable: {self.enable}",
            f"net_size: {self.net_size}",
            f"map_file: {self.map_file}",
            f"config_file: {self.config_file}",
            f"weight_file: {self.weight_file}",
            f"restore_descriptor: {self.restore_descriptor}",
            f"restore_fitting_net: {self.restore_fitting_net}",
            f"quantize_descriptor: {self.quantize_descriptor}",
            f"quantize_fitting_net: {self.quantize_fitting_net}",
        )
        for message in NVNMD_WELCOME + NVNMD_CITATION + NVNMD_CONFIG:
            log.info(message)


# global configuration for nvnmd
nvnmd_cfg = NvnmdConfig(jdata_deepmd_input["nvnmd"])
