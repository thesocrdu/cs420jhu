/*******************************************************************************
*
*  kernelSmoother
*
*  This provides a CUDA implementation of a kernel smooother.
*   http://en.wikipedia.org/wiki/Kernel_smoother
*  The particular kernel in this file is a nearest neighbor smoother
*  in order to keep the code as simple to understand as possible.
*
*  This is implemeneted for 2-d square grids.
*
*  Parameters of note are all in struct CUDAGrid.
*    gridWidth -- size of the grid is gridWidth^2
*    kernelWidth -- region around point x,y to smooth
*        must be odd, i.e. 2k+1 smooths box with corners (x-k,y-k) to (x+k,y+k)
*    blockWidth -- number of processors per block.
*        must be ((cg.gridWidth-(cg.kernelWidth-1))^2 % (blockWidth^2)) == 0 
*        i.e. the smoothed regions must be of blocksize increments.
*
*  The smoothed region is only defined for the interior that has the kernel
*   defined inside the boundary, e.g. for gridWidth=10, kernelWidth=2 the
*   region from 2,2 to 7,7 will be smoothed. 
*
********************************************************************************/

/*******************************************************************************
*
*  CUDA concepts
*
*  This file shows how to use many features of CUDA:
*     2d grids
*     pitch allocation
*     shared memory
*
********************************************************************************/

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <assert.h>
#include <sys/time.h>

#include <cuda.h>


// Need these at compile time now...yuck!
//   the 2-d array inside CUDA must be sized.
const unsigned GridWidth = 4112;
const unsigned KernelWidth = 17;
const unsigned BlockWidth = 16;

//
// CUDAGrid: structure to define geometry parameter.
//   set one of these up in main()
//
typedef struct
{
  unsigned gridWidth;
  unsigned kernelWidth;
  unsigned blockWidth;
} CUDAGrid;


/*------------------------------------------------------------------------------
* Name: NNSmoothKernel
* Action:  The CUDA kernel that implements kernel smoothing.
*             Yuck, that's two senses of kernel.
*-----------------------------------------------------------------------------*/
__global__ void NNSmoothKernel ( float* pFieldIn, float* pFieldOut, size_t pitch, CUDAGrid cg )
{ 
  extern __shared__ float shared[][BlockWidth+KernelWidth-1];

  // pitch is in bytes, figure out the number of elements for addressing
  unsigned pitchels = pitch/sizeof(float);

  // compute the halfwidth-1 of the kernel
  unsigned koffset = (cg.kernelWidth-1)/2;


  // Construct the 2d shared memory array it needs to be blockWidth+(kernelWidth-1)/2 square
  // Each node loads one element
  shared[threadIdx.x][threadIdx.y] = 
    pFieldIn [  (blockIdx.y * blockDim.y + threadIdx.y) * pitchels 
                   +  blockIdx.x * blockDim.x + threadIdx.x ];

  // And determines if it needs to load it's x-neigbor
  if ( threadIdx.x < cg.kernelWidth -1 )
  {
    shared[threadIdx.x + cg.blockWidth][threadIdx.y] = 
      pFieldIn [  (blockIdx.y * blockDim.y + threadIdx.y) * pitchels 
                     +  blockIdx.x * blockDim.x + threadIdx.x + cg.blockWidth ];
  }

  // And determines if it needs to load it's y-neigbor
  if ( threadIdx.y < cg.kernelWidth -1 )
  {
    shared[threadIdx.x][threadIdx.y + cg.blockWidth] = 
      pFieldIn [  (blockIdx.y * blockDim.y + threadIdx.y + cg.blockWidth) * pitchels 
                     +  blockIdx.x * blockDim.x + threadIdx.x];
  }

  // And determines if it needs to load it's xy-neigbor
  if ( ( threadIdx.y < cg.kernelWidth -1 ) && ( threadIdx.x < cg.kernelWidth -1 ))
  {
    shared[threadIdx.x + cg.blockWidth][threadIdx.y + cg.blockWidth] = 
      pFieldIn [  (blockIdx.y * blockDim.y + threadIdx.y + cg.blockWidth) * pitchels 
                     +  blockIdx.x * blockDim.x + threadIdx.x + cg.blockWidth];
  }

  __syncthreads();

  pFieldOut [ (threadIdx.y+koffset)*pitchels + threadIdx.x+koffset ] = shared [threadIdx.x][threadIdx.y];


  // Variable to accumulate the smoothed value
  float value = 0.0;

  // The grid indexes start from 
  unsigned xindex = ( blockIdx.x * blockDim.x + threadIdx.x) + koffset; 
  unsigned yindex = ( blockIdx.y * blockDim.y + threadIdx.y) + koffset; 

  // Get the value from the kernel
  for ( unsigned j=0; j<cg.kernelWidth; j++ )
  {
    for ( unsigned i=0; i<cg.kernelWidth; i++ )
    {
      value += shared [threadIdx.x+i] [threadIdx.y+j];
    }
  }
  
  // Divide by the number of elements in the kernel
  value /= cg.kernelWidth*cg.kernelWidth;

  // Write the value out 
  pFieldOut [ yindex*pitchels + xindex ] = value;


} 


/*------------------------------------------------------------------------------
* Name:  SmoothField
* Action:  Host entry point to kernel smoother
*-----------------------------------------------------------------------------*/
bool SmoothField ( float* pHostFieldIn, float *pHostFieldOut, CUDAGrid cg ) 
{ 
  float * pDeviceFieldIn = 0;
  float * pDeviceFieldOut = 0;

  size_t pitch, pitchout;

  struct timeval ta, tb, tc, td;

  // Check the grid dimensions and extract parameters.  See top description about restrictions
  assert ((( cg.kernelWidth -1 )%2) == 0 );     // Width is odd
  unsigned blockSize = cg.blockWidth * cg.blockWidth;  
  assert( ((cg.gridWidth-(cg.kernelWidth-1))*(cg.gridWidth-(cg.kernelWidth-1)) % blockSize) == 0 );

  gettimeofday ( &ta, NULL );

  // Place the data set on device memory
  cudaMallocPitch((void**)&pDeviceFieldIn, &pitch, cg.gridWidth*sizeof(float), cg.gridWidth ); 
  cudaMemcpy2D ( pDeviceFieldIn, pitch,
                 pHostFieldIn, cg.gridWidth*sizeof(float), cg.gridWidth*sizeof(float), cg.gridWidth,
                 cudaMemcpyHostToDevice); 

  // Allocate the output
  cudaMallocPitch((void**)&pDeviceFieldOut, &pitchout, cg.gridWidth*sizeof(float), cg.gridWidth ); 

  gettimeofday ( &tb, NULL );

  // Construct a 2d grid/block
  const dim3 DimBlock ( cg.blockWidth, cg.blockWidth );
  const dim3 DimGrid ( (cg.gridWidth-(cg.kernelWidth-1))/cg.blockWidth , 
                       (cg.gridWidth-(cg.kernelWidth-1))/cg.blockWidth );
  const unsigned shmemSize = ( cg.blockWidth + cg.kernelWidth -1 ) * ( cg.blockWidth + cg.kernelWidth -1 ) * sizeof (float);

  // Invoke the kernel
  NNSmoothKernel <<<DimGrid,DimBlock, shmemSize>>> ( pDeviceFieldIn, pDeviceFieldOut, pitch, cg ); 

  gettimeofday ( &tc, NULL );

  // Retrieve the results
  cudaMemcpy2D(pHostFieldOut, cg.gridWidth*sizeof(float), 
               pDeviceFieldOut, pitch, cg.gridWidth*sizeof(float), cg.gridWidth,
               cudaMemcpyDeviceToHost); 

  gettimeofday ( &td, NULL );


  if ( ta.tv_usec < td.tv_usec )
  {
    printf ("Elapsed total time (s/m): %d:%d\n", td.tv_sec - ta.tv_sec, td.tv_usec - ta.tv_usec );
  } else {
    printf ("Elapsed total time (s/m): %d:%d\n", td.tv_sec - ta.tv_sec - 1, 1000000 - td.tv_usec + ta.tv_usec );
  }

  if ( tb.tv_usec < tc.tv_usec )
  {
    printf ("Elapsed kernel time (s/m): %d:%d\n", tc.tv_sec - tb.tv_sec, tc.tv_usec - tb.tv_usec );
  } else {
    printf ("Elapsed kernel time (s/m): %d:%d\n", tc.tv_sec - tb.tv_sec - 1, 1000000 - tc.tv_usec + tb.tv_usec );
  }

  return true;
}



/*------------------------------------------------------------------------------
* Name:  initField
* Action:  Initialize a field to predictable values.
*    This is a useful format for debugging, because values 
*    accumulate to their initial value.
*-----------------------------------------------------------------------------*/
void initField ( unsigned dim, float* pField )
{
  for ( unsigned j=0; j<dim; j++ )
  {
    for ( unsigned i=0; i<dim; i++ )
    {
      pField[j*dim+i] = j + i;
    }
  }
}


/*------------------------------------------------------------------------------
* Name:  main
* Action:  Entry point
*-----------------------------------------------------------------------------*/
int main ()
{

  // Define the grid
  CUDAGrid cg;
  cg.gridWidth = GridWidth;
  cg.kernelWidth = KernelWidth;
  cg.blockWidth = BlockWidth;

  // Create the input field
  float *field = (float *) malloc ( cg.gridWidth * cg.gridWidth * sizeof(float));
  initField ( cg.gridWidth, field );

  // Create the output field
  float *out = (float *) malloc ( cg.gridWidth * cg.gridWidth * sizeof(float));

  // Call the kernel
  SmoothField ( field, out, cg );

  // Print the output field (for debugging purposes.
/*  unsigned koffset = (cg.kernelWidth-1)/2;
  for ( unsigned j=0; j< cg.gridWidth; j++ )
  {
    for ( unsigned i=0; i< cg.gridWidth; i++ )
    {
      if ( ( i >= koffset ) && 
           ( j >= koffset ) &&
           ( i < ( cg.gridWidth - koffset )) &&
           ( j < ( cg.gridWidth - koffset )) )
      {
        printf ("%4.0f, ", out[j*cg.gridWidth + i]);
      }
      else
      {
        printf ("  na, ");
      }
    }  
    printf ("\n");
  }
*/
}
/*******************************************************************************
*
*  Revsion History
*
*  $Log: kernSm.shmem.cu,v $
*  Revision 1.1  2009/07/22 16:54:20  randal
*  OK, got them good.
*
*  Revision 1.2  2009/07/22 15:21:41  randal
*  This is the preferred impelmentation.
*
*
*******************************************************************************/
