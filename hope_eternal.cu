#include <iostream>
#include <stdio.h>
#include <cuda_runtime.h>
#include <helper_math.h>
#include <stdlib.h>

#define NumThreadsZ 1
#define RenderWidth 1920
#define RenderHeight 1080
//#define SamplesPerPixel 5000
#define InfinityBound 1e20

using namespace std;
// constants
__constant__ float3 white={1.0f, 1.0f, 1.0f}; 
__constant__ float3 black={0.0f,0.0f,0.0f};
__constant__ float3 Xaxis={1.0,0.0,0.0};
__constant__ float3 Yaxis={0.0,1.0,0.0};
__constant__ float3 OriginInit={50, 52, 295.6};
__constant__ float3 DirInitRaw={0, -0.042612, -1};
__constant__ float FoV=0.5135;
 
//some utility functions 
inline float clamp(float x)
{ 
	return x < 0.0f ? 0.0f : x > 1.0f ? 1.0f : x; 
} 

inline int RGBtoInt(float x)	  
{ 
	return int(pow(clamp(x), 1 / 2.2) * 255 + 0.5); 
}
//random number generator
__device__ static float RandGen(unsigned int *seed0, unsigned int *seed1) 
{
	*seed0 = 36969 * ((*seed0) & 65535) + ((*seed0) >> 16);  // hash the seeds using bitwise AND and bitshifts
	*seed1 = 18000 * ((*seed1) & 65535) + ((*seed1) >> 16);

	unsigned int ires = ((*seed0) << 16) + (*seed1);	
	union 
	{
		float f;
	  	unsigned int ui;
	} res;

	res.ui = (ires & 0x007fffff) | 0x40000000;

	return (res.f - 2.f) / 2.f;	
}

//Define types of reflections
enum ReflectionType
{
	DIFF,
	SPEC,
	REFR
};
//Ray structure
struct Ray
{
	float3 Origin;
	float3 Direction;

	__device__ Ray(float3 orig_init, float3 dir_init) : Origin(orig_init), Direction(dir_init) {} 
};

//Sphere structure
struct Sphere
{
	float Radius;
	float3 Position,Emmisivity,Colour;
	ReflectionType Reflector;

	__device__ float SphereCollisionPoint(const Ray &inRay) const
	{
		float3 Distance=Position-inRay.Origin;
		float CollisionPoint,DecisionPoint=0.0001f;
		float b=dot(Distance,inRay.Direction);
		float Discriminant=b*b-dot(Distance,Distance)+Radius*Radius;
		if(Discriminant<0)
			return 0;
		else
			Discriminant=sqrtf(Discriminant);

		
		return	(CollisionPoint=b-Discriminant)>DecisionPoint?CollisionPoint:((CollisionPoint=b+Discriminant)>DecisionPoint?CollisionPoint:0);

	}
};

/* Scene definition 
{ float radius,
	{ float3 position },
	{ float3 emission },
	{ float3 colour },
	refl_type 
}
*/

__constant__ Sphere spheres[]=
{
	//Left 
	{ 1e5f,
		{ 1e5f + 1.0f, 40.8f, 81.6f },
		{ 0.0f, 0.0f, 0.0f },
		{ 0.75f, 0.25f, 0.25f },
		DIFF 
	}, 
	//Rght 
	{ 1e5f,
		{ -1e5f + 99.0f, 40.8f, 81.6f },
		{ 0.0f, 0.0f, 0.0f },
		{ .25f, .25f, .75f },
		DIFF 
	}, 
	//Back 
	{ 1e5f,
		{ 50.0f, 40.8f, 1e5f },
		{ 0.0f, 0.0f, 0.0f },
		{ .75f, .75f, .75f },
		DIFF 
	}, 
	//Front 
	{ 1e5f,
		{ 50.0f, 40.8f, -1e5f + 600.0f },
		{ 0.0f, 0.0f, 0.0f },
		{ 1.00f, 1.00f, 1.00f },
		DIFF 
	},
	//Bottom  
	{ 1e5f,
		{ 50.0f, 1e5f, 81.6f },
		{ 0.0f, 0.0f, 0.0f },
		{ .75f, .75f, .75f },
		DIFF 
	}, 	
	//Top
	{ 1e5f,
		{ 50.0f, -1e5f + 81.6f, 81.6f },
		{ 0.0f, 0.0f, 0.0f },
		{ .75f, .75f, .75f },
		DIFF 
	}, 
	// small sphere 1
	{ 16.5f,
		{ 27.0f, 16.5f, 47.0f },
		{ 0.0f, 0.0f, 0.0f  },
		{0.999f, 0.999f, 0.999f},
		REFR
	}, 
	// small sphere 2
	{ 16.5f,
		{ 73.0f, 16.5f, 78.0f },
		{ 0.0f, 0.0f, 0.0f },
		{ 0.999f, 0.999f, 0.999f },
		SPEC
	}, 
	// Light
	{ 600.0f,
		{ 50.0f, 681.6f - 0.27f, 81.6f },
		{ 6.0f, 6.0f, 6.0f },
		{ 0.9f, 0.2f, 0.086f },
		DIFF 
	}  

};


//Ray and scene intersection
__device__ inline bool DoesRayIntersectScene(const Ray &inRay, float &ClosestIntersection, int &HitID)
{
	int i;
	float SceneBlock=sizeof(spheres)/sizeof(Sphere);
	ClosestIntersection=InfinityBound;
	float NewClosestIntersection;
	for (i = int(SceneBlock); i--; )		
		if ((NewClosestIntersection=spheres[i].SphereCollisionPoint(inRay)) && NewClosestIntersection<ClosestIntersection)
		{
			ClosestIntersection=NewClosestIntersection;
			HitID=i;
		}
	
	return ClosestIntersection<InfinityBound;
		
}

__device__ float3 GetRadiance(Ray &inRay,unsigned int *seed1,unsigned int *seed2)
{

	float3 ColourAccumulator = black;
	float3 mask = white;
	
	int LightBounce;	
	
	for (LightBounce = 0; LightBounce < 4; ++LightBounce)		
	{
		float ClosestIntersection;
		int HitID=0;
		
		if (!DoesRayIntersectScene(inRay,ClosestIntersection,HitID))
				return black;

		const Sphere &HitObj=spheres[HitID];

		float3 HitPoint=inRay.Origin+inRay.Direction*ClosestIntersection;
		float3 Normal=normalize(HitPoint-HitObj.Position);
		float3 FrontNormal=dot(Normal,inRay.Direction)<0 ? Normal : Normal*(-1); 
		
		ColourAccumulator+=mask*HitObj.Emmisivity;
		
		
		float3 UpdateMask;
		if (HitObj.Reflector==SPEC)		
		{

			float3 NewDir=inRay.Direction - 2.0f*Normal*dot(Normal,inRay.Direction);
			
			inRay.Origin=HitPoint + FrontNormal*0.01f;
			inRay.Direction=NewDir;
			UpdateMask=2*HitObj.Colour;
		}
		else if(HitObj.Reflector==DIFF)
		{
			float Azimuth = 2 * M_PI * RandGen(seed1, seed2);
			float Elevation = RandGen(seed1, seed2);
			float SqrtElev = sqrtf(Elevation); 

			float3 u = normalize(cross((fabs(FrontNormal.x) > 0.1 ? Yaxis : Xaxis), FrontNormal));
			float3 v = cross(FrontNormal,u);		
			float3 NewDir=normalize(u*cos(Azimuth)*SqrtElev + v*sin(Azimuth)*SqrtElev + FrontNormal*sqrtf(1 - Elevation));																	

			inRay.Origin=HitPoint + FrontNormal*0.05f;
			inRay.Direction=NewDir;
			UpdateMask=2*HitObj.Colour;
			
		}
		else
		{
			bool enter= dot(Normal,FrontNormal) >0;
			float ref_air=1.0f;
			float ref_glass=1.5f;
			float ior= enter ? ref_air/ref_glass: ref_glass/ref_air;
			float des=dot(inRay.Direction, FrontNormal);
			float cos2t= 1.0f- ior*ior*(1.0f-des*des);
			if (cos2t<0.0f)
			{
				inRay.Direction= inRay.Direction-2.0f*Normal*dot(Normal, inRay.Direction);
				inRay.Origin=HitPoint + FrontNormal*0.01f;
			}
			else{
				float3 T_dir = normalize(inRay.Direction*ior-Normal*((enter?1:-1)* (des*ior+ sqrtf(cos2t))));
				float c= 1.0f - (enter? -des:dot(T_dir,Normal));
				float R0= (ref_glass- ref_air)*(ref_glass- ref_air)/(ref_glass+ ref_air)*(ref_glass+ ref_air);
				float Re = R0 + (1.f- R0)*c*c*c*c*c;
				float Tr=1-Re;
				float P= 0.25+ 0.5f*Re;
				float RP=Re/P;
				float TP=Tr / (1.0f-P);
				if (RandGen(seed1, seed2)>0.25)
				{
					UpdateMask *=RP;
					inRay.Direction=inRay.Direction-2.0f*Normal*dot(Normal, inRay.Direction);
					inRay.Origin=HitPoint + FrontNormal*0.02f;
				}
				else{
					UpdateMask *=TP;
					inRay.Direction = T_dir;
					inRay.Origin=HitPoint + FrontNormal*0.0005f;
				}
			}
			
		}
		
		mask *= UpdateMask; 		
		
		
	}
	
		
	

	return ColourAccumulator;
}

__global__ void TracePath2(float3 *RenderedImage,const int SamplesPerPixel)
{
	unsigned int x = blockIdx.x*blockDim.x + threadIdx.x;   
	unsigned int y = blockIdx.y*blockDim.y + threadIdx.y;
	unsigned int CurrentPixel = (RenderHeight - y - 1)*RenderWidth + x; 

	unsigned int seed1 = x;
	unsigned int seed2 = y;
	
	Ray CameraRay(OriginInit,normalize(DirInitRaw));
	float3 DirOffsetX=make_float3(RenderWidth*FoV/RenderHeight,0.0f,0.0f);
	float3 DirOffsetY = normalize(cross(DirOffsetX, CameraRay.Direction)) * FoV;
	float3 FinalPixCol = black;

	for (int CurrentSample = 0; CurrentSample < SamplesPerPixel; CurrentSample++)
	{		
		float3 DirectionOffset = CameraRay.Direction + DirOffsetX*((0.25 + x) / RenderWidth - 0.5) + DirOffsetY*((0.25 + y) / RenderHeight - 0.5);		
		Ray temp_ray(CameraRay.Origin + DirectionOffset * 140, normalize(DirectionOffset));		
		FinalPixCol+=GetRadiance(temp_ray, &seed1, &seed2)*(1.0 / SamplesPerPixel); 
	}

	RenderedImage[CurrentPixel]=make_float3(clamp(FinalPixCol.x, 0.0f, 1.0f), clamp(FinalPixCol.y, 0.0f, 1.0f), clamp(FinalPixCol.z, 0.0f, 1.0f));
}

int main(int argc, char const *argv[])
{
	int PixPtr;	
	char* endPtr;
	
	int NumThreadsX=strtol(argv[1],&endPtr,10);
	int NumThreadsY=NumThreadsX;
	int SamplesPerPixel=strtol(argv[2],&endPtr,10);
	float3* h_RenderedImage = new float3[RenderWidth*RenderHeight*sizeof(float3)]; 
	float3* d_RenderedImage;	

	cudaMalloc(&d_RenderedImage, RenderWidth * RenderHeight * sizeof(float3));
	
	dim3 block(NumThreadsX,NumThreadsY,NumThreadsZ);   
	dim3 grid(RenderWidth / NumThreadsX, RenderHeight / NumThreadsY, NumThreadsZ);

	printf("Starting Path Trace Kernel\n");
	TracePath2 <<< grid,block>>> (d_RenderedImage,SamplesPerPixel);	
	cudaMemcpy(h_RenderedImage, d_RenderedImage, RenderWidth * RenderHeight *sizeof(float3), cudaMemcpyDeviceToHost);  	
	cudaFree(d_RenderedImage);  
	printf("Finished and freed\n");

	FILE *f = fopen(argv[3], "w");          
	fprintf(f, "P3\n%d %d\n%d\n", RenderWidth, RenderHeight, 255);

	for (PixPtr = 0; PixPtr < RenderWidth*RenderHeight; PixPtr++)  
		fprintf(f, "%d %d %d ", RGBtoInt(h_RenderedImage[PixPtr].x),RGBtoInt(h_RenderedImage[PixPtr].y),RGBtoInt(h_RenderedImage[PixPtr].z));

	printf("Saved image\n");

	delete[] h_RenderedImage;
	
	return 0;
}
