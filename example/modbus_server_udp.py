import asyncio
from pymodbus.server.async_io import ModbusUdpServer
from pymodbus.device import ModbusDeviceIdentification
from pymodbus.datastore import ModbusSequentialDataBlock
from pymodbus.datastore import ModbusSlaveContext, ModbusServerContext
import logging

# Configure the service logging
logging.basicConfig()
log = logging.getLogger()
log.setLevel(logging.DEBUG)

async def run_modbus_server():
    # 配置数据存储区
    store = ModbusSlaveContext(
        di=ModbusSequentialDataBlock(0, [20] * 100),
        co=ModbusSequentialDataBlock(0, [20] * 100),
        hr=ModbusSequentialDataBlock(0, [20] * 100),
        ir=ModbusSequentialDataBlock(0, [20] * 100))
    context = ModbusServerContext(slaves=store, single=True)

    # 配置设备标识
    identity = ModbusDeviceIdentification()
    identity.VendorName = 'Pymodbus'
    identity.ProductCode = 'PM'
    identity.VendorUrl = 'http://github.com/riptideio/pymodbus/'
    identity.ProductName = 'Pymodbus Server'
    identity.ModelName = 'Pymodbus Server'
    identity.MajorMinorRevision = '1.0'

    # 启动UDP服务器
    await ModbusUdpServer(context=context, identity=identity, address=("127.0.0.1", 5021)).serve_forever()
    
if __name__ == "__main__":
    asyncio.run(run_modbus_server())
