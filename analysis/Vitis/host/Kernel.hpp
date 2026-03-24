/*
 * Copyright (C) 2025-2026 Gerrit Pape (gerrit.pape@uni-paderborn.de)
 *
 * This file is part of PRESAGe.
 *
 * PRESAGe is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * any later version.
 *
 * PRESAGe is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with PRESAGe. If not, see <https://www.gnu.org/licenses/>.
 */
#include "experimental/xrt_kernel.h"

class Bitstream
{
public:
    Bitstream(uint32_t index, std::string name, bool emulation) : index(index), name(name), emulation(emulation)
    {
        device = xrt::device(index);
        std::stringstream paths;
        paths << name << "_" << (emulation ? "sw_emu" : "hw") << ".xclbin";
        path = paths.str();
        xclbin_uuid = device.load_xclbin(path);
    }

    Bitstream() {}

    void reset()
    {
        device = xrt::device(index);
        xclbin_uuid = device.load_xclbin(path);
    }

    uint32_t index;
    std::string name;
    std::string path;
    bool emulation;
    xrt::device device;
    xrt::uuid xclbin_uuid;
};

template <typename T>
class UnitaryKernel
{
public:
    UnitaryKernel(Bitstream bitstream, std::string operation, std::string precision) : bitstream(bitstream)
    {
        std::stringstream name;
        name << operation << "_" << precision;
        operation = name.str();
        name << ":{" << operation << "_" << precision << "_1}";
        kernel = xrt::kernel(bitstream.device, bitstream.xclbin_uuid, name.str());

    }

    UnitaryKernel(Bitstream bitstream, std::string operation) : operation(operation), bitstream(bitstream)
    {
        std::stringstream name;
        name << operation << ":{" << operation << "_1}";
        kernel = xrt::kernel(bitstream.device, bitstream.xclbin_uuid, name.str());
    }

    UnitaryKernel() {}

    void prepare(uint64_t num)
    {
        num = num;
        in_bo = xrt::bo(bitstream.device, num * sizeof(T), xrt::bo::flags::normal, kernel.group_id(1));
        out_bo = xrt::bo(bitstream.device, num * sizeof(T), xrt::bo::flags::normal, kernel.group_id(2));

        xrt_run = xrt::run(kernel);

        xrt_run.set_arg(0, num);
    }

    void run(T *in)
    {
        in_bo.write(in);
        in_bo.sync(XCL_BO_SYNC_BO_TO_DEVICE);

        xrt_run.set_arg(1, in_bo);
        xrt_run.set_arg(2, out_bo);

        xrt_run.start();
    }

    bool timeout(uint32_t timeout_ms = 3000)
    {
        return xrt_run.wait(std::chrono::milliseconds(timeout_ms)) == ERT_CMD_STATE_TIMEOUT;
    }

    void write_back(T *out)
    {
        out_bo.sync(XCL_BO_SYNC_BO_FROM_DEVICE);
        out_bo.read(out);
    }

    std::string operation;
private:
    Bitstream bitstream;
    xrt::bo in_bo, out_bo;
    xrt::kernel kernel;
    xrt::run xrt_run;
    uint32_t instance;
    uint64_t num;
};


