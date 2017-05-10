#include "Orb.h"
#include "FAST.h"
#include "Profiler.h"
#include <thread>

using namespace cv;
Orb::Orb() : rBRIEF()
{
	_mode = MODE_RBRIEF;
}
Orb::Orb(int s, MODE mode) : rBRIEF(s)
{
	_mode = mode;
}
Orb::Orb(std::vector<BRIEF::BinaryTest> tests, MODE mode) : rBRIEF(tests)
{
	_mode = mode;
}

void Orb::computeOrientation(cuArray<unsigned char>& frame, std::vector<float4>& corners, int width, int height)
{
	int cc = corners.size() < CORNER_LIMIT ? corners.size() : CORNER_LIMIT;
	AngleMap.upload(corners.data(), cc);
	ComputeOrientation << < corners.size() / 32, 32 >> > (frame, AngleMap, cc, width, height);
	AngleMap.download(corners.data(), cc);
}

std::vector<float4> Orb::detectKeypoints(cuArray<uchar>& ibuffer, cuArray<uchar>& aux, int thres, const int arc_length, const int width, const int height,const int limit, const int padding)
{
	std::vector<float4> corners;
	cv::Mat auxmat = cv::Mat(width, height, CV_8UC1);
	FAST << < dim3(width / FAST_TILE, height / FAST_TILE), dim3(FAST_TILE, FAST_TILE) >> > (ibuffer, aux, thres, arc_length, width, height);
	aux.download(auxmat.data);
	int x = padding + padding*width;
	for (uint i = padding; i < height - padding; ++i,x += padding * 2)
	{
		for (uint j = padding; j < width - padding; ++j,++x)
		{
			uint cvalue = auxmat.data[x];
			if (cvalue > 0)
			{
				corners.push_back({ (float)j,(float)i,0,0 });
			}
		}
	}
	if (limit>0)
	{
		AngleMap.upload(corners.data(), corners.size());
		FAST_Refine << < corners.size() / 32, 32 >> >(ibuffer, AngleMap, corners.size(), width, height);
		AngleMap.download(corners.data(), corners.size());
		std::sort(corners.begin(), corners.end(), [](float4& c1, float4& c2) {
			return c1.w > c2.w;
		});
		int minc = corners.size() >= limit ? limit : corners.size();
		corners = std::vector<float4>(corners.begin(), corners.begin() + minc);
	}
	computeOrientation(ibuffer, corners, width, height);
	return corners;
}


std::vector<float4> Orb::detectKeypoints(cv::Mat& grey, int thres, const int arc_length,const int limit, const int padding)
{
	int frameWidth = grey.cols, frameHeight = grey.rows;
	cuArray<uchar> gpuInputBuffer(frameWidth*frameHeight), gpuOutputBuffer(frameWidth*frameHeight);
	gpuInputBuffer.upload(grey.data);
	std::thread first([&] { boxFilter(grey, grey, -1, Size(5, 5)); });
	std::vector<float4> corners = detectKeypoints(gpuInputBuffer, gpuOutputBuffer, thres, arc_length, frameWidth, frameHeight,limit);
	first.join();
	return corners;
}

std::vector<BRIEF::BRIEF::Feature> Orb::extractFeatures(uint8_t** image, std::vector<float4> keypoints) const
{
	std::vector<cv::Point2f> corners;
	std::vector<float> angles;
	for (int i = 0; i < keypoints.size(); ++i)
	{
		corners.push_back(cv::Point2f(keypoints[i].x, keypoints[i].y));
		angles.push_back(keypoints[i].z);
	}
	if(_mode == MODE::MODE_RBRIEF)
		return rBRIEF::extractFeatures(image, corners, angles);
	else
		return BRIEF::extractFeatures(image, corners);

}


Orb Orb::fromFile(char* filename)
{
	std::cout << std::string(filename);
	std::fstream f(filename,std::ios::in);
	int x1, x2, y1, y2;
	std::vector<BRIEF::BRIEF::BinaryTest> bp;
	while (f >> x1 >> y1 >> x2 >> y2)
	{
		bp.push_back({ (int8_t)x1,(int8_t)y1,(int8_t)x2,(int8_t)y2 });
		std::cout << x1 << " " << y1 << " " << x2 << " " << y2 << std::endl;
	}
	return Orb(bp);
}