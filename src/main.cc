#include <pxr/usd/usd/stage.h>

#include <filesystem>
#include <iostream>

namespace fs = std::filesystem;

int main(int argc, char* argv[])
{
    if (argc < 2)
    {
        std::cerr << "Usage: " << argv[0] << " <usd_file_path>" << std::endl;
        return 1;
    }

    fs::path usd_path = argv[1];

    if (!fs::exists(usd_path))
    {
        std::cerr << "Error: file not found: " << usd_path.string() << std::endl;
        return 1;
    }

    std::cout << "Loading USD stage: " << usd_path.string() << std::endl;

    pxr::UsdStageRefPtr stage = pxr::UsdStage::Open(usd_path.string());

    if (!stage)
    {
        std::cerr << "Error: failed to open USD stage" << std::endl;
        return 1;
    }

    std::cout << "Successfully loaded USD stage" << std::endl;
    std::cout << "Root layer: " << stage->GetRootLayer()->GetIdentifier() << std::endl;

    return 0;
}
