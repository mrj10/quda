#include <quda_internal.h>
#include <face_quda.h>
#include <cstdio>
#include <cstdlib>
#include <quda.h>
#include <string.h>

#define QMP_COMMS
#ifdef QMP_COMMS
#include <qmp.h>
QMP_msgmem_t mm_send_fwd;
QMP_msgmem_t mm_from_fwd;
QMP_msgmem_t mm_send_back;
QMP_msgmem_t mm_from_back;
QMP_msghandle_t mh_send_fwd;
QMP_msghandle_t mh_send_back;
QMP_msghandle_t mh_from_fwd;
QMP_msghandle_t mh_from_back;
#endif

using namespace std;

FaceBuffer allocateFaceBuffer(int Vs, int V, int stride, Precision precision)
{
   FaceBuffer ret;
   ret.Vs = Vs;
   ret.V = V;
   ret.stride=stride;
   ret.precision=precision;
  
   // Buffers hold half spinors
   ret.nbytes = ret.Vs*12*precision;

   // add extra space for the norms for half precision
   if (precision == QUDA_HALF_PRECISION) {
     ret.nbytes += ret.Vs*sizeof(float);
   }

#ifndef __DEVICE_EMULATION__
   cudaMallocHost(&(ret.my_fwd_face), ret.nbytes);
#else
    ret.my_fwd_face = malloc(ret.nbytes);
#endif

    if( !ret.my_fwd_face ) { 
      errorQuda("Unable to allocate my_fwd_face");
    }

#ifndef __DEVICE_EMULATION__
    cudaMallocHost(&(ret.my_back_face), ret.nbytes);
#else
    ret.my_back_face = malloc(ret.nbytes);
#endif

    if( !ret.my_back_face ) { 
      errorQuda("Unable to allocate my_back_face");
    }

#ifndef __DEVICE_EMULATION__
    cudaMallocHost(&(ret.from_fwd_face), ret.nbytes);
#else
    ret.from_fwd_face = malloc(ret.nbytes);
#endif

    if( !ret.from_fwd_face ) { 
      errorQuda("Unable to allocate from_fwd_face");
    }


#ifndef __DEVICE_EMULATION__
    cudaMallocHost(&(ret.from_back_face), ret.nbytes);
#else
    ret.from_back_face = malloc(ret.nbytes);
#endif


    if( !ret.from_back_face ) { 
      errorQuda("Unable to allocate from_back_face");
    }


#ifdef QMP_COMMS
    mm_send_fwd = QMP_declare_msgmem(ret.my_fwd_face, ret.nbytes);
    if( mm_send_fwd == NULL ) { 
      errorQuda("Unable to allocate send fwd message mem");
    }
    mm_send_back = QMP_declare_msgmem(ret.my_back_face, ret.nbytes);
    if( mm_send_back == NULL ) { 
      errorQuda("Unable to allocate send back message mem");
    }


    mm_from_fwd = QMP_declare_msgmem(ret.from_fwd_face, ret.nbytes);
    if( mm_from_fwd == NULL ) { 
      errorQuda("Unable to allocate recv from fwd message mem");
    }

    mm_from_back = QMP_declare_msgmem(ret.from_back_face, ret.nbytes);
    if( mm_from_back == NULL ) { 
      errorQuda("Unable to allocate recv from back message mem");
    }

    mh_send_fwd = QMP_declare_send_relative(mm_send_fwd,
					    3,
					    +1, 
					    0);
    if( mh_send_fwd == NULL ) {
      errorQuda("Unable to allocate forward send");
    }

    mh_send_back = QMP_declare_send_relative(mm_send_back, 
					     3,
					     -1,
					     0);
    if( mh_send_back == NULL ) {
      errorQuda("Unable to allocate backward send");
    }
    
    
    mh_from_fwd = QMP_declare_receive_relative(mm_from_fwd,
					    3,
					    +1,
					    0);
    if( mh_from_fwd == NULL ) {
      errorQuda("Unable to allocate forward recv");
    }
    
    mh_from_back = QMP_declare_receive_relative(mm_from_back, 
					     3,
					     -1,
					     0);
    if( mh_from_back == NULL ) {
      errorQuda("Unable to allocate backward recv");
    }

#endif

    return ret;
}


void freeFaceBuffer(FaceBuffer f)
{

#ifdef QMP_COMMS
  QMP_free_msghandle(mh_send_fwd);
  QMP_free_msghandle(mh_send_back);
  QMP_free_msghandle(mh_from_fwd);
  QMP_free_msghandle(mh_from_back);
  QMP_free_msgmem(mm_send_fwd);
  QMP_free_msgmem(mm_send_back);
  QMP_free_msgmem(mm_from_fwd);
  QMP_free_msgmem(mm_send_back);
#else

#ifndef __DEVICE_EMULATION__
  cudaFreeHost(f.my_fwd_face);
  cudaFreeHost(f.my_back_face);
  cudaFreeHost(f.from_fwd_face);
  cudaFreeHost(f.from_back_face);
#else 
  free(f.my_fwd_face);
  free(f.my_back_face);
  free(f.from_fwd_face);
  free(f.from_back_face);
#endif
#endif
  f.my_fwd_face=NULL;
  f.my_back_face=NULL;
  f.from_fwd_face=NULL;
  f.from_back_face=NULL;

}

// This would need to change for going truly parallel..
// Right now, its just a question of copying faces. My front face
// is what I send forward so it will be my 'from-back' face
// and my back face is what I send backward -- will be my from front face
void exchangeFaces(FaceBuffer bufs)
{

#ifdef QMP_COMMS


  QMP_start(mh_from_fwd);
  QMP_start(mh_from_back);

  QMP_start(mh_send_back);
  QMP_start(mh_send_fwd);

  QMP_wait(mh_send_back);
  QMP_wait(mh_send_fwd);

  QMP_wait(mh_from_fwd);
  QMP_wait(mh_from_back);

  
#else 

#ifndef __DEVICE_EMULATION__
  cudaMemcpy(bufs.from_fwd_face, bufs.my_back_face, bufs.nbytes, 
	     cudaMemcpyHostToHost);

  cudaMemcpy(bufs.from_back_face, bufs.my_fwd_face, bufs.nbytes, 
	     cudaMemcpyHostToHost);

#else
  memcpy(bufs.from_fwd_face, bufs.my_back_face, bufs.nbytes);
  memcpy(bufs.from_back_face, bufs.my_fwd_face, bufs.nbytes);
#endif
#endif
   
}

void exchangeFacesStart(FaceBuffer face, ParitySpinor in, int dagger)
{
#ifdef QMP_COMMS
  // Prepost all receives
  QMP_start(mh_from_fwd);
  QMP_start(mh_from_back);
#endif
  // Gather into face...
  gatherFromSpinor(face, in, dagger);

#ifdef QMP_COMMS
  // Begin all sends 
  QMP_start(mh_send_back);
  QMP_start(mh_send_fwd);
#endif
}


void exchangeFacesWait(FaceBuffer face, ParitySpinor out, int dagger)
{
#ifdef QMP_COMMS
  // Make sure all outstanding sends are done
  QMP_wait(mh_send_back);
  QMP_wait(mh_send_fwd);

  // Finish receives
  QMP_wait(mh_from_back);
  QMP_wait(mh_from_fwd);
#else
// NO QMP -- do copies
#ifndef __DEVICE_EMULATION__
  cudaMemcpy(bufs.from_fwd_face, bufs.my_back_face, bufs.nbytes, 
	     cudaMemcpyHostToHost);

  cudaMemcpy(bufs.from_back_face, bufs.my_fwd_face, bufs.nbytes, 
	     cudaMemcpyHostToHost);

#else
  memcpy(bufs.from_fwd_face, bufs.my_back_face, bufs.nbytes);
  memcpy(bufs.from_back_face, bufs.my_fwd_face, bufs.nbytes);
#endif
#endif

  // Scatter faces.
  scatterToPads(out, face, dagger);
}

template <int vecLen, typename Float>
void gather12Float(Float* dest, Float* spinor, int Vs, int V, int stride, bool upper, bool tIsZero)
{
  int Npad = 12/vecLen;  // Number of Pad's in one half spinor...
  int lower_spin_offset=vecLen*Npad*stride;	
  int t_zero_offset=0; // T=0 is the first VS block
  int Nt_minus_one_offset=vecLen*(V - Vs); // N_t -1 = V-Vs & vecLen is from FloatN.

 
  // QUDA Memcpy NPad's worth. 
  //  -- Dest will point to the right beginning PAD. 
  //  -- Each Pad has size vecLen*Vs Floats. 
  //  --  There is vecLen*Stride Floats from the
  //           start of one PAD to the start of the next
  for(int i=0; i < Npad; i++) {
    if( upper ) { 
      if( tIsZero ) { 
        cudaMemcpy((void *)(dest + vecLen*i*Vs), 
                   (void *)(spinor + t_zero_offset + i*vecLen*stride),
	           vecLen*Vs*sizeof(Float),
                   cudaMemcpyDeviceToHost );      
      }
      else {
        cudaMemcpy((void *)(dest + vecLen*i*Vs), 
                   (void *)(spinor + Nt_minus_one_offset + i*vecLen*stride),
	           vecLen*Vs*sizeof(Float),
                   cudaMemcpyDeviceToHost );      
      }
    }
    else {
      if( tIsZero ) { 
        cudaMemcpy((void *)(dest + vecLen*i*Vs), 
                   (void *)(spinor + lower_spin_offset + t_zero_offset + i*vecLen*stride),
	           vecLen*Vs*sizeof(Float),
                   cudaMemcpyDeviceToHost );      
      }
      else {
        cudaMemcpy((void *)(dest + vecLen*i*Vs), 
                   (void *)(spinor + lower_spin_offset + Nt_minus_one_offset + i*vecLen*stride),
	           vecLen*Vs*sizeof(Float),
                   cudaMemcpyDeviceToHost );      
      }
    }
  }
}

// like the above but for the norms required for QUDA_HALF_PRECISION
template <typename Float>
void gatherNorm(Float* dest, Float* norm, int Vs, int V, int stride, bool tIsZero)
{
  int t_zero_offset=0; // T=0 is the first VS block
  int Nt_minus_one_offset=V - Vs; // N_t -1 = V-Vs.
 
  if( tIsZero ) { 
    cudaMemcpy((void *)dest, 
	       (void *)(norm + t_zero_offset),
	       Vs*sizeof(Float),
	       cudaMemcpyDeviceToHost );      
  } else {
    cudaMemcpy((void *)dest, 
	       (void *)(norm + Nt_minus_one_offset),
	       Vs*sizeof(Float),
	       cudaMemcpyDeviceToHost );      
  }

}



  // QUDA Memcpy 3 Pad's worth. 
  //  -- Dest will point to the right beginning PAD. 
  //  -- Each Pad has size vecLen * Vs Floats. 
  //  --  There is 4Stride Floats from the
  //           start of one PAD to the start of the next

template <int vecLen, typename Float>
void scatter12Float(Float* spinor, Float* buf, int Vs, int V, int stride, bool upper)
{
  int Npad = 12/vecLen;
  int spinor_end = 2*Npad*vecLen*stride;
  int face_size = Npad*vecLen*Vs;
  
  if( upper ) { 
    cudaMemcpy((void *)(spinor + spinor_end), (void *)(buf), face_size*sizeof(Float), cudaMemcpyHostToDevice);
  }
  else {
#if 1
    cudaMemcpy((void *)(spinor + spinor_end + face_size), (void *)(buf), face_size*sizeof(Float), cudaMemcpyHostToDevice);
#else
    for(int i=0; i < Npad; i++) {
      cudaMemcpy((void *)(spinor+vecLen*(V+(i+Npad)*stride) ), (void *)(buf+vecLen*i*Vs), vecLen*Vs*sizeof(Float), cudaMemcpyHostToDevice); 
    }
#endif
  }
  
}

// half precision norm version of the above
template <typename Float>
void scatterNorm(Float* norm, Float* buf, int Vs, int V, int stride, bool upper)
{
  int norm_end = stride;
  int face_size = Vs;
  if (upper) { // upper goes in the first norm zone
    cudaMemcpy((void *)(norm + norm_end), (void *)(buf), Vs*sizeof(Float), cudaMemcpyHostToDevice);  
  } else { // lower goes in the second norm zone
    cudaMemcpy((void *)(norm + norm_end + face_size), (void *)(buf), Vs*sizeof(Float), cudaMemcpyHostToDevice);  
  }
}

void gatherFromSpinor(FaceBuffer face, ParitySpinor in, int dagger)
{
  
  // I need to gather the faces with opposite Checkerboard
  // Depending on whether I do dagger or not I want top 2 components
  // from forward, and bottom 2 components from backward
  if (!dagger) { 

    // Not HC: send lower components back, receive them from forward
    // lower components = buffers 4,5,6

    if (in.precision == QUDA_DOUBLE_PRECISION) {
      // lower_spins => upper = false, t=0, so tIsZero=true 
      gather12Float<2>((double *)(face.my_back_face), (double *)in.spinor, 
		       face.Vs, face.V, face.stride, false, true);
    
      // Not Hermitian conjugate: send upper spinors forward/recv from back
      // upper spins => upper = true,t=Nt-1 => tIsZero=false
      gather12Float<2>((double *)(face.my_fwd_face), (double *)in.spinor,
		       face.Vs, face.V, face.stride, true, false);
    
    } else if (in.precision == QUDA_SINGLE_PRECISION) {
      // lower_spins => upper = false, t=0, so tIsZero=true 
      gather12Float<4>((float *)(face.my_back_face), (float *)in.spinor, 
		       face.Vs, face.V, face.stride, false, true);
    
      // Not Hermitian conjugate: send upper spinors forward/recv from back
      // upper spins => upper = true,t=Nt-1 => tIsZero=false
      gather12Float<4>((float *)(face.my_fwd_face), (float *)in.spinor,
		       face.Vs, face.V, face.stride, true, false);
    
    } else {       
      // lower_spins => upper = false, t=0, so tIsZero=true 
      gather12Float<4>((short *)(face.my_back_face), (short *)in.spinor, 
		       face.Vs, face.V, face.stride, false, true);
    
      gatherNorm((float*)((short*)face.my_back_face+12*face.Vs), 
		 (float*)in.spinorNorm, face.Vs, face.V, face.stride, true);

      // Not Hermitian conjugate: send upper spinors forward/recv from back
      // upper spins => upper = true,t=Nt-1 => tIsZero=false
      gather12Float<4>((short *)(face.my_fwd_face), (short *)in.spinor,
		       face.Vs, face.V, face.stride, true, false);

      gatherNorm((float*)((short*)face.my_fwd_face+12*face.Vs), 
		 (float*)in.spinorNorm, face.Vs, face.V, face.stride, false);
    }
 

  }
  else { 

    if (in.precision == QUDA_DOUBLE_PRECISION) {
      // HC: send lower components fwd, receive them from back
      // Lower Spins => upper = false, t=Nt-1      => tIsZero = true
      gather12Float<2>((double *)(face.my_fwd_face), (double *)in.spinor, 
		       face.Vs, face.V, face.stride, false, false);
    
      // HC: Send upper components back, receive them from front
      // upper spins => upper = true,t=Nt-1 => tIsZero=false
      gather12Float<2>((double *)(face.my_back_face), (double *)in.spinor,
		       face.Vs, face.V, face.stride, true, true);
    
    } else if (in.precision == QUDA_SINGLE_PRECISION) {
      // Lower Spins => upper = false, t=Nt-1      => tIsZero = true
      gather12Float<4>((float *)(face.my_fwd_face), (float *)in.spinor, 
		       face.Vs, face.V, face.stride, false, false);
    
      // HC: Send upper components back, receive them from front
      // upper spins => upper = true,t=Nt-1 => tIsZero=false
      gather12Float<4>((float *)(face.my_back_face), (float *)in.spinor,
		       face.Vs, face.V, face.stride, true, true);
    
    } else {       
      // lower_spins => upper = false, t=0, so tIsZero=true 
      gather12Float<4>((short *)(face.my_fwd_face), (short *)in.spinor, 
		       face.Vs, face.V, face.stride, false, false);
    
      gatherNorm((float*)((short*)face.my_fwd_face+12*face.Vs), 
		 (float*)in.spinorNorm, face.Vs, face.V, face.stride, false);

      // HC: Send upper components back, receive them from front
      //UpperSpins => upper = true, t=0 => tIsZero = true
      gather12Float<4>((short *)(face.my_back_face), (short *)in.spinor,
		       face.Vs, face.V, face.stride, true, true);

      gatherNorm((float*)((short*)face.my_back_face+12*face.Vs), 
		 (float*)in.spinorNorm, face.Vs, face.V, face.stride, true);
    }

  }
}

void scatterToPads(ParitySpinor out, FaceBuffer face, int dagger)
{
 

  // I need to gather the faces with opposite Checkerboard
  // Depending on whether I do dagger or not I want top 2 components
  // from forward, and bottom 2 components from backward
  if (!dagger) { 

    if (out.precision == QUDA_DOUBLE_PRECISION) {
      // Not HC: send lower components back, receive them from forward
      // lower components = buffers 4,5,6
      scatter12Float<2>((double *)out.spinor, (double *)face.from_fwd_face, 
			face.Vs, face.V, face.stride, false); // LOWER
      
      // Not H: Send upper components forward, receive them from back
      scatter12Float<2>((double *)out.spinor, (double *)face.from_back_face,
			face.Vs, face.V, face.stride, true);        // Upper
    } else if (out.precision == QUDA_SINGLE_PRECISION) {
      // Not HC: send lower components back, receive them from forward
      // lower components = buffers 4,5,6
      scatter12Float<4>((float *)out.spinor, (float *)face.from_fwd_face, 
			face.Vs, face.V, face.stride, false); // LOWER
      
      // Not H: Send upper components forward, receive them from back
      scatter12Float<4>((float *)out.spinor, (float *)face.from_back_face,
			face.Vs, face.V, face.stride, true);        // Upper
    } else {
      // Not HC: send lower components back, receive them from forward
      // lower components = buffers 4,5,6
      scatter12Float<4>((short *)out.spinor, (short *)face.from_fwd_face, 
			face.Vs, face.V, face.stride, false); // LOWER
      
      scatterNorm((float*)out.spinorNorm, (float*)((short*)face.from_fwd_face+12*face.Vs), 
		  face.Vs, face.V, face.stride, false);

      // Not H: Send upper components forward, receive them from back
      scatter12Float<4>((short *)out.spinor, (short *)face.from_back_face,
			face.Vs, face.V, face.stride, true);        // Upper

      scatterNorm((float*)out.spinorNorm, (float*)((short*)face.from_back_face+12*face.Vs), 
		  face.Vs, face.V, face.stride, true);

    }
    
  } else { 
    if (out.precision == QUDA_DOUBLE_PRECISION) {
      // HC: send lower components fwd, receive them from back
      // lower components = buffers 4,5,6
      scatter12Float<2>((double *)out.spinor, (double *)face.from_back_face,
			face.Vs, face.V, face.stride, false);       // Lower
      
      // upper components = buffers 1, 2,3, go forward (into my_fwd face)
      scatter12Float<2>((double *)out.spinor, (double *)face.from_fwd_face,
			face.Vs, face.V, face.stride, true );       
    } else if (out.precision == QUDA_SINGLE_PRECISION) {
      // HC: send lower components fwd, receive them from back
      // lower components = buffers 4,5,6
      scatter12Float<4>((float *)out.spinor, (float *)face.from_back_face,
			face.Vs, face.V, face.stride, false);       // Lower
      
      // upper components = buffers 1, 2,3, go forward (into my_fwd face)
      scatter12Float<4>((float *)out.spinor, (float *)face.from_fwd_face,
			face.Vs, face.V, face.stride, true );
    } else {
      // HC: send lower components fwd, receive them from back
      // lower components = buffers 4,5,6
      scatter12Float<4>((short *)out.spinor, (short *)face.from_back_face,
			face.Vs, face.V, face.stride, false);       // Lower
      
      scatterNorm((float*)out.spinorNorm, (float*)((short*)face.from_back_face+12*face.Vs), 
		  face.Vs, face.V, face.stride, false);

      // upper components = buffers 1, 2,3, go forward (into my_fwd face)
      scatter12Float<4>((short *)out.spinor, (short *)face.from_fwd_face,
			face.Vs, face.V, face.stride, true );
 
      scatterNorm((float*)out.spinorNorm, (float*)((short*)face.from_fwd_face+12*face.Vs), 
		  face.Vs, face.V, face.stride, true);

    }

  }
}

