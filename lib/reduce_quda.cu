#include <blas_quda.h>
#include <tune_quda.h>
#include <float_vector.h>
#include <color_spinor_field_order.h>

#if (__COMPUTE_CAPABILITY__ >= 130)
#define QudaSumFloat double
#define QudaSumFloat2 double2
#define QudaSumFloat3 double3
#else
#define QudaSumFloat doublesingle
#define QudaSumFloat2 doublesingle2
#define QudaSumFloat3 doublesingle3
#include <double_single.h>
#endif

#define REDUCE_MAX_BLOCKS 65536

#define checkSpinor(a, b)						\
  {									\
    if (a.Precision() != b.Precision())					\
      errorQuda("precisions do not match: %d %d", a.Precision(), b.Precision()); \
    if (a.Length() != b.Length())					\
      errorQuda("lengths do not match: %d %d", a.Length(), b.Length());	\
    if (a.Stride() != b.Stride())					\
      errorQuda("strides do not match: %d %d", a.Stride(), b.Stride());	\
  }

static struct {
  int x[QUDA_MAX_DIM];
  int stride;
} blasConstants;

// These are used for reduction kernels
static QudaSumFloat *d_reduce=0;
static QudaSumFloat *h_reduce=0;
static QudaSumFloat *hd_reduce=0;
static cudaEvent_t reduceEnd;
    
namespace quda {
  namespace blas {

    QudaTune getTuning();
    QudaVerbosity getVerbosity();
    cudaStream_t* getStream();
    
    void initReduce()
    { 
      // reduction buffer size
      size_t bytes = 3*REDUCE_MAX_BLOCKS*sizeof(QudaSumFloat);

      if (!d_reduce) d_reduce = (QudaSumFloat *) device_malloc(bytes);
    
      // these arrays are actually oversized currently (only needs to be QudaSumFloat3)
    
      // if the device supports host-mapped memory then use a host-mapped array for the reduction
      if (!h_reduce) {
	// only use zero copy reductions when using 64-bit
#if (defined(_MSC_VER) && defined(_WIN64)) || defined(__LP64__)
	if(deviceProp.canMapHostMemory) {
	  h_reduce = (QudaSumFloat *) mapped_malloc(bytes);	
	  cudaHostGetDevicePointer(&hd_reduce, h_reduce, 0); // set the matching device pointer
	} else 
#endif 
	  {
	    h_reduce = (QudaSumFloat *) pinned_malloc(bytes);
	    hd_reduce = d_reduce;
	  }
	memset(h_reduce, 0, bytes); // added to ensure that valgrind doesn't report h_reduce is unitialised
      }
    
      cudaEventCreateWithFlags(&reduceEnd, cudaEventDisableTiming);
    
      checkCudaError();
    }

    void endReduce(void)
    {
      if (d_reduce) {
	device_free(d_reduce);
	d_reduce = 0;
      }
      if (h_reduce) {
	host_free(h_reduce);
	h_reduce = 0;
      }
      hd_reduce = 0;
    
      cudaEventDestroy(reduceEnd);
    }

    namespace reduce {

#include <texture.h>
#include <reduce_core.h>
    
    } // namespace reduce

    /**
       Base class from which all reduction functors should derive.
    */
    template <typename ReduceType, typename Float2, typename FloatN>
    struct ReduceFunctor {
    
      //! pre-computation routine called before the "M-loop"
      virtual __device__ __host__ void pre() { ; }
    
      //! where the reduction is usually computed and any auxiliary operations
      virtual __device__ __host__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, 
						  FloatN &z, FloatN &w, FloatN &v) = 0;
    
      //! post-computation routine called after the "M-loop"
      virtual __device__ __host__ void post(ReduceType &sum) { ; }
    
    };

    /**
       Return the L2 norm of x
    */
    __device__ __host__ double _norm2(const double2 &a) { return a.x*a.x + a.y*a.y; }
    __device__ __host__ float _norm2(const float2 &a) { return a.x*a.x + a.y*a.y; }
    __device__ __host__ float _norm2(const float4 &a) { return a.x*a.x + a.y*a.y + a.z*a.z + a.w*a.w; }

    template <typename ReduceType, typename Float2, typename FloatN>
#if (__COMPUTE_CAPABILITY__ >= 200)
    struct norm2_ : public ReduceFunctor<ReduceType, Float2, FloatN> {
#else
      struct norm2_ {
#endif
	norm2_(const Float2 &a, const Float2 &b) { ; }
	__device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z,FloatN  &w, FloatN &v) 
	{ sum += _norm2(x); }
	static int streams() { return 1; } //! total number of input and output streams
	static int flops() { return 2; } //! flops per element
      };

      double norm2(const ColorSpinorField &x) {
	ColorSpinorField &y = (ColorSpinorField&)x; // FIXME
	return reduce::reduceCuda<double,QudaSumFloat,QudaSumFloat,norm2_,0,0,0,0,0,false>
	  (make_double2(0.0, 0.0), make_double2(0.0, 0.0), y, y, y, y, y);
      }

      /**
	 Return the real dot product of x and y
      */
      __device__ __host__ double _dot(const double2 &a, const double2 &b) { return a.x*b.x + a.y*b.y; }
      __device__ __host__ float _dot(const float2 &a, const float2 &b) { return a.x*b.x + a.y*b.y; }
      __device__ __host__ float _dot(const float4 &a, const float4 &b) { return a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w; }

      template <typename ReduceType, typename Float2, typename FloatN>
#if (__COMPUTE_CAPABILITY__ >= 200)
      struct dot_ : public ReduceFunctor<ReduceType, Float2, FloatN> {
#else
	struct dot_ {
#endif
	  dot_(const Float2 &a, const Float2 &b) { ; }
	  __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) 
	  { sum += _dot(x,y); }
	  static int streams() { return 2; } //! total number of input and output streams
	  static int flops() { return 2; } //! flops per element
	};

	double reDotProduct(ColorSpinorField &x, ColorSpinorField &y) {
	  return reduce::reduceCuda<double,QudaSumFloat,QudaSumFloat,dot_,0,0,0,0,0,false>
	    (make_double2(0.0, 0.0), make_double2(0.0, 0.0), x, y, x, x, x);
	}

	/**
	   First performs the operation y[i] = a*x[i]
	   Return the norm of y
	*/
	template <typename ReduceType, typename Float2, typename FloatN>
#if (__COMPUTE_CAPABILITY__ >= 200)
	struct axpyNorm2 : public ReduceFunctor<ReduceType, Float2, FloatN> {
#else
	  struct axpyNorm2 {
#endif
	    Float2 a;
	    axpyNorm2(const Float2 &a, const Float2 &b) : a(a) { ; }
	    __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) { 
	      y += a.x*x; sum += _norm2(y); }
	    static int streams() { return 3; } //! total number of input and output streams
	    static int flops() { return 4; } //! flops per element
	  };

	  double axpyNorm(const double &a, ColorSpinorField &x, ColorSpinorField &y) {
	    return reduce::reduceCuda<double,QudaSumFloat,QudaSumFloat,axpyNorm2,0,1,0,0,0,false>
	      (make_double2(a, 0.0), make_double2(0.0, 0.0), x, y, x, x, x);
	  }

	  /**
	     First performs the operation y[i] = x[i] - y[i]
	     Second returns the norm of y
	  */
	  template <typename ReduceType, typename Float2, typename FloatN>
#if (__COMPUTE_CAPABILITY__ >= 200)
	  struct xmyNorm2 : public ReduceFunctor<ReduceType, Float2, FloatN> {
#else
	    struct xmyNorm2 {
#endif
	      xmyNorm2(const Float2 &a, const Float2 &b) { ; }
	      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) { 
		y = x - y; sum += _norm2(y); }
	      static int streams() { return 3; } //! total number of input and output streams
	      static int flops() { return 3; } //! flops per element
	    };

	    double xmyNorm(ColorSpinorField &x, ColorSpinorField &y) {
	      return reduce::reduceCuda<double,QudaSumFloat,QudaSumFloat,xmyNorm2,0,1,0,0,0,false>
		(make_double2(0.0, 0.0), make_double2(0.0, 0.0), x, y, x, x, x);
	    }


	    /**
	       Functor to perform the operation y += a * x  (complex-valued)
	    */

	    __device__ __host__ void Caxpy_(const float2 &a, const float4 &x, float4 &y) {
	      y.x += a.x*x.x; y.x -= a.y*x.y;
	      y.y += a.y*x.x; y.y += a.x*x.y;
	      y.z += a.x*x.z; y.z -= a.y*x.w;
	      y.w += a.y*x.z; y.w += a.x*x.w;
	    }

	    __device__ __host__ void Caxpy_(const float2 &a, const float2 &x, float2 &y) {
	      y.x += a.x*x.x; y.x -= a.y*x.y;
	      y.y += a.y*x.x; y.y += a.x*x.y;
	    }

	    __device__ __host__ void Caxpy_(const double2 &a, const double2 &x, double2 &y) {
	      y.x += a.x*x.x; y.x -= a.y*x.y;
	      y.y += a.y*x.x; y.y += a.x*x.y;
	    }

	    /**
	       First performs the operation y[i] = a*x[i] + y[i] (complex-valued)
	       Second returns the norm of y
	    */
	    template <typename ReduceType, typename Float2, typename FloatN>
#if (__COMPUTE_CAPABILITY__ >= 200)
	    struct caxpyNorm2 : public ReduceFunctor<ReduceType, Float2, FloatN> {
#else
	      struct caxpyNorm2 {
#endif
		Float2 a;
		caxpyNorm2(const Float2 &a, const Float2 &b) : a(a) { ; }
		__device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) { 
		  Caxpy_(a, x, y); sum += _norm2(y); }
		static int streams() { return 3; } //! total number of input and output streams
		static int flops() { return 6; } //! flops per element
	      };

	      double caxpyNorm(const Complex &a, ColorSpinorField &x, ColorSpinorField &y) {
		return reduce::reduceCuda<double,QudaSumFloat,QudaSumFloat,caxpyNorm2,0,1,0,0,0,false>
		  (make_double2(a.real(), a.imag()), make_double2(0.0, 0.0), x, y, x, x, x);
	      }

	      /**
		 double caxpyXmayNorm(float a, float *x, float *y, n){}
   
		 First performs the operation y[i] = a*x[i] + y[i]
		 Second performs the operator x[i] -= a*z[i]
		 Third returns the norm of x
	      */
	      template <typename ReduceType, typename Float2, typename FloatN>
#if (__COMPUTE_CAPABILITY__ >= 200)
	      struct caxpyxmaznormx : public ReduceFunctor<ReduceType, Float2, FloatN> {
#else
		struct caxpyxmaznormx {
#endif
		  Float2 a;
		  caxpyxmaznormx(const Float2 &a, const Float2 &b) : a(a) { ; }
		  __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) { Caxpy_(a, x, y); x-= a.x*z; sum += _norm2(x); }
		  static int streams() { return 5; } //! total number of input and output streams
		  static int flops() { return 10; } //! flops per element
		};

		double caxpyXmazNormX(const Complex &a, ColorSpinorField &x, 
				      ColorSpinorField &y, ColorSpinorField &z) {
		  return reduce::reduceCuda<double,QudaSumFloat,QudaSumFloat,caxpyxmaznormx,1,1,0,0,0,false>
		    (make_double2(a.real(), a.imag()), make_double2(0.0, 0.0), x, y, z, x, x);
		}

		/**
		   double cabxpyAxNorm(float a, complex b, float *x, float *y, n){}
   
		   First performs the operation y[i] += a*b*x[i]
		   Second performs x[i] *= a
		   Third returns the norm of x
		*/
		template <typename ReduceType, typename Float2, typename FloatN>
#if (__COMPUTE_CAPABILITY__ >= 200)
		struct cabxpyaxnorm : public ReduceFunctor<ReduceType, Float2, FloatN> {
#else
		  struct cabxpyaxnorm {
#endif
		    Float2 a;
		    Float2 b;
		    cabxpyaxnorm(const Float2 &a, const Float2 &b) : a(a), b(b) { ; }
		    __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) { x *= a.x; Caxpy_(b, x, y); sum += _norm2(y); }
		    static int streams() { return 4; } //! total number of input and output streams
		    static int flops() { return 10; } //! flops per element
		  };

		  double cabxpyAxNorm(const double &a, const Complex &b, 
				      ColorSpinorField &x, ColorSpinorField &y) {
		    return reduce::reduceCuda<double,QudaSumFloat,QudaSumFloat,cabxpyaxnorm,1,1,0,0,0,false>
		      (make_double2(a, 0.0), make_double2(b.real(), b.imag()), x, y, x, x, x);
		  }

		  /**
		     Returns complex-valued dot product of x and y
		  */
		  __device__ __host__ double2 cdot_(const double2 &a, const double2 &b) 
		  { return make_double2(a.x*b.x + a.y*b.y, a.x*b.y - a.y*b.x); }
		  __device__ __host__ double2 cdot_(const float2 &a, const float2 &b) 
		  { return make_double2(a.x*b.x + a.y*b.y, a.x*b.y - a.y*b.x); }
		  __device__ __host__ double2 cdot_(const float4 &a, const float4 &b) 
		  { return make_double2(a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w, a.x*b.y - a.y*b.x + a.z*b.w - a.w*b.z); }

		  template <typename ReduceType, typename Float2, typename FloatN>
#if (__COMPUTE_CAPABILITY__ >= 200)
		  struct Cdot : public ReduceFunctor<ReduceType, Float2, FloatN> {
#else
		    struct Cdot {
#endif
		      Cdot(const Float2 &a, const Float2 &b) { ; }
		      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) { sum += cdot_(x,y); }
		      static int streams() { return 2; } //! total number of input and output streams
		      static int flops() { return 4; } //! flops per element
		    };

		    Complex cDotProduct(ColorSpinorField &x, ColorSpinorField &y) {
		      double2 cdot = reduce::reduceCuda<double2,QudaSumFloat2,QudaSumFloat,Cdot,0,0,0,0,0,false>
			(make_double2(0.0, 0.0), make_double2(0.0, 0.0), x, y, x, x, x);
		      return Complex(cdot.x, cdot.y);
		    }

		    /**
		       double2 xpaycDotzy(float2 *x, float a, float2 *y, float2 *z, int n) {}
   
		       First performs the operation y = x + a*y
		       Second returns cdot product (z,y)
		    */
		    template <typename ReduceType, typename Float2, typename FloatN>
#if (__COMPUTE_CAPABILITY__ >= 200)
		    struct xpaycdotzy : public ReduceFunctor<ReduceType, Float2, FloatN> {
#else
		      struct xpaycdotzy {
#endif
			Float2 a;
			xpaycdotzy(const Float2 &a, const Float2 &b) : a(a) { ; }
			__device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) { y = x + a.x*y; sum += cdot_(z,y); }
			static int streams() { return 4; } //! total number of input and output streams
			static int flops() { return 6; } //! flops per element
		      };

		      Complex xpaycDotzy(ColorSpinorField &x, const double &a, ColorSpinorField &y, ColorSpinorField &z) {
			double2 cdot = reduce::reduceCuda<double2,QudaSumFloat2,QudaSumFloat,xpaycdotzy,0,1,0,0,0,false>
			  (make_double2(a, 0.0), make_double2(0.0, 0.0), x, y, z, x, x);
			return Complex(cdot.x, cdot.y);
		      }

		      /**
			 double caxpyDotzy(float a, float *x, float *y, float *z, n){}
   
			 First performs the operation y[i] = a*x[i] + y[i]
			 Second returns the dot product (z,y)
		      */
		      template <typename ReduceType, typename Float2, typename FloatN>
#if (__COMPUTE_CAPABILITY__ >= 200)
		      struct caxpydotzy : public ReduceFunctor<ReduceType, Float2, FloatN> {
#else
			struct caxpydotzy {
#endif
			  Float2 a;
			  caxpydotzy(const Float2 &a, const Float2 &b) : a(a) { ; }
			  __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) { Caxpy_(a, x, y); sum += cdot_(z,y); }
			  static int streams() { return 4; } //! total number of input and output streams
			  static int flops() { return 8; } //! flops per element
			};

			Complex caxpyDotzy(const Complex &a, ColorSpinorField &x, ColorSpinorField &y,
					   ColorSpinorField &z) {
			  double2 cdot = reduce::reduceCuda<double2,QudaSumFloat2,QudaSumFloat,caxpydotzy,0,1,0,0,0,false>
			    (make_double2(a.real(), a.imag()), make_double2(0.0, 0.0), x, y, z, x, x);
			  return Complex(cdot.x, cdot.y);
			}

			/**
			   First returns the dot product (x,y)
			   Returns the norm of x
			*/
			__device__ __host__ double3 cdotNormA_(const double2 &a, const double2 &b) 
			{ return make_double3(a.x*b.x + a.y*b.y, a.x*b.y - a.y*b.x, a.x*a.x + a.y*a.y); }
			__device__ __host__ double3 cdotNormA_(const float2 &a, const float2 &b) 
			{ return make_double3(a.x*b.x + a.y*b.y, a.x*b.y - a.y*b.x, a.x*a.x + a.y*a.y); }
			__device__ __host__ double3 cdotNormA_(const float4 &a, const float4 &b) 
			{ return make_double3(a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w, 
					      a.x*b.y - a.y*b.x + a.z*b.w - a.w*b.z,
					      a.x*a.x + a.y*a.y + a.z*a.z + a.w*a.w); }

			template <typename ReduceType, typename Float2, typename FloatN>
#if (__COMPUTE_CAPABILITY__ >= 200)
			struct CdotNormA : public ReduceFunctor<ReduceType, Float2, FloatN> {
#else
			  struct CdotNormA {
#endif
			    CdotNormA(const Float2 &a, const Float2 &b) { ; }
			    __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) { sum += cdotNormA_(x,y); }
			    static int streams() { return 2; } //! total number of input and output streams
			    static int flops() { return 6; } //! flops per element
			  };

			  double3 cDotProductNormA(ColorSpinorField &x, ColorSpinorField &y) {
			    return reduce::reduceCuda<double3,QudaSumFloat3,QudaSumFloat,CdotNormA,0,0,0,0,0,false>
			      (make_double2(0.0, 0.0), make_double2(0.0, 0.0), x, y, x, x, x);
			  }

			  /**
			     First returns the dot product (x,y)
			     Returns the norm of y
			  */
			  __device__ __host__ double3 cdotNormB_(const double2 &a, const double2 &b) 
			  { return make_double3(a.x*b.x + a.y*b.y, a.x*b.y - a.y*b.x, b.x*b.x + b.y*b.y); }
			  __device__ __host__ double3 cdotNormB_(const float2 &a, const float2 &b) 
			  { return make_double3(a.x*b.x + a.y*b.y, a.x*b.y - a.y*b.x, b.x*b.x + b.y*b.y); }
			  __device__ __host__ double3 cdotNormB_(const float4 &a, const float4 &b) 
			  { return make_double3(a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w, a.x*b.y - a.y*b.x + a.z*b.w - a.w*b.z,
						b.x*b.x + b.y*b.y + b.z*b.z + b.w*b.w); }

			  template <typename ReduceType, typename Float2, typename FloatN>
#if (__COMPUTE_CAPABILITY__ >= 200)
			  struct CdotNormB : public ReduceFunctor<ReduceType, Float2, FloatN> {
#else
			    struct CdotNormB {
#endif
			      CdotNormB(const Float2 &a, const Float2 &b) { ; }
			      __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) { sum += cdotNormB_(x,y); }
			      static int streams() { return 2; } //! total number of input and output streams
			      static int flops() { return 6; } //! flops per element
			    };

			    double3 cDotProductNormB(ColorSpinorField &x, ColorSpinorField &y) {
			      return reduce::reduceCuda<double3,QudaSumFloat3,QudaSumFloat,CdotNormB,0,0,0,0,0,false>
				(make_double2(0.0, 0.0), make_double2(0.0, 0.0), x, y, x, x, x);
			    }

			    /**
			       This convoluted kernel does the following: 
			       z += a*x + b*y, y -= b*w, norm = (y,y), dot = (u, y)
			    */
			    template <typename ReduceType, typename Float2, typename FloatN>
#if (__COMPUTE_CAPABILITY__ >= 200)
			    struct caxpbypzYmbwcDotProductUYNormY_ : public ReduceFunctor<ReduceType, Float2, FloatN> {
#else
			      struct caxpbypzYmbwcDotProductUYNormY_ {
#endif
				Float2 a;
				Float2 b;
				caxpbypzYmbwcDotProductUYNormY_(const Float2 &a, const Float2 &b) : a(a), b(b) { ; }
				__device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) { Caxpy_(a, x, z); Caxpy_(b, y, z); Caxpy_(-b, w, y); sum += cdotNormB_(v,y); }
				static int streams() { return 7; } //! total number of input and output streams
				static int flops() { return 18; } //! flops per element
			      };

			      double3 caxpbypzYmbwcDotProductUYNormY(const Complex &a, ColorSpinorField &x, 
								     const Complex &b, ColorSpinorField &y,
								     ColorSpinorField &z, ColorSpinorField &w,
								     ColorSpinorField &u) {
				return reduce::reduceCuda<double3,QudaSumFloat3,QudaSumFloat,caxpbypzYmbwcDotProductUYNormY_,0,1,1,0,0,false>
				  (make_double2(a.real(), a.imag()), make_double2(b.real(), b.imag()), x, y, z, w, u);
			      }


			      /**
				 Specialized kernel for the modified CG norm computation for
				 computing beta.  Computes y = y + a*x and returns norm(y) and
				 dot(y, delta(y)) where delta(y) is the difference between the
				 input and out y vector.
			      */
			      template <typename ReduceType, typename Float2, typename FloatN>
#if (__COMPUTE_CAPABILITY__ >= 200)
			      struct axpyCGNorm2 : public ReduceFunctor<ReduceType, Float2, FloatN> {
#else
				struct axpyCGNorm2 {
#endif
				  Float2 a;
				  axpyCGNorm2(const Float2 &a, const Float2 &b) : a(a) { ; }
				  __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) { 
				    FloatN y_new = y + a.x*x;
				    sum.x += _norm2(y_new); 
				    sum.y += _dot(y_new, y_new-y);
				    y = y_new;
				  }
				  static int streams() { return 3; } //! total number of input and output streams
				  static int flops() { return 6; } //! flops per real element
				};

				Complex axpyCGNorm(const double &a, ColorSpinorField &x, ColorSpinorField &y) {
				  double2 cg_norm = reduce::reduceCuda<double2,QudaSumFloat2,QudaSumFloat,axpyCGNorm2,0,1,0,0,0,false>
				    (make_double2(a, 0.0), make_double2(0.0, 0.0), x, y, x, x, x);
				  return Complex(cg_norm.x, cg_norm.y);
				}

#if (__COMPUTE_CAPABILITY__ >= 200)

				/**
				   This kernel returns (x, x) and (r,r) and also returns the so-called
				   heavy quark norm as used by MILC: 1 / N * \sum_i (r, r)_i / (x, x)_i, where
				   i is site index and N is the number of sites.
     
				   When this kernel is launched, we must enforce that the parameter M
				   in the launcher corresponds to the number of FloatN fields used to
				   represent the spinor, e.g., M=6 for Wilson and M=3 for staggered.
				   This is only the case for half-precision kernels by default.  To
				   enable this, the siteUnroll template parameter must be set true
				   when reduceCuda is instantiated.
				*/
				template <typename ReduceType, typename Float2, typename FloatN>
				struct HeavyQuarkResidualNorm_ : public ReduceFunctor<ReduceType, Float2, FloatN> {
				  Float2 a;
				  Float2 b;
				  ReduceType aux;
				  HeavyQuarkResidualNorm_(const Float2 &a, const Float2 &b) : a(a), b(b) { ; }
    
				  __device__ __host__ void pre() { aux.x = 0; aux.y = 0; }
    
				  __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) 
				  { aux.x += _norm2(x); aux.y += _norm2(y); }
    
				  //! sum the solution and residual norms, and compute the heavy-quark norm
				  __device__ __host__ void post(ReduceType &sum) 
				  { 
				    sum.x += aux.x; sum.y += aux.y; sum.z += (aux.x > 0.0) ? (aux.y / aux.x) : 1.0; 
				  }
    
				  static int streams() { return 2; } //! total number of input and output streams
				  static int flops() { return 4; } //! undercounts since it excludes the per-site division
				};
  
				double3 HeavyQuarkResidualNorm(ColorSpinorField &x, ColorSpinorField &r) {
				  double3 rtn = reduce::reduceCuda<double3,QudaSumFloat3,QudaSumFloat,HeavyQuarkResidualNorm_,0,0,0,0,0,true>
				    (make_double2(0.0, 0.0), make_double2(0.0, 0.0), x, r, r, r, r);
#ifdef MULTI_GPU
				  rtn.z /= (x.Volume()*comm_size());
#else
				  rtn.z /= x.Volume();
#endif
				  return rtn;
				}
  
				/**
				   Variant of the HeavyQuarkResidualNorm kernel: this takes three
				   arguments, the first two are summed together to form the
				   solution, with the third being the residual vector.  This removes
				   the need an additional xpy call in the solvers, impriving
				   performance.
				*/
				template <typename ReduceType, typename Float2, typename FloatN>
				struct xpyHeavyQuarkResidualNorm_ : public ReduceFunctor<ReduceType, Float2, FloatN> {
				  Float2 a;
				  Float2 b;
				  ReduceType aux;
				  xpyHeavyQuarkResidualNorm_(const Float2 &a, const Float2 &b) : a(a), b(b) { ; }
    
				  __device__ __host__ void pre() { aux.x = 0; aux.y = 0; }
    
				  __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) 
				  { aux.x += _norm2(x + y); aux.y += _norm2(z); }
    
				  //! sum the solution and residual norms, and compute the heavy-quark norm
				  __device__ __host__ void post(ReduceType &sum) 
				  { 
				    sum.x += aux.x; sum.y += aux.y; sum.z += (aux.x > 0.0) ? (aux.y / aux.x) : 1.0; 
				  }
    
				  static int streams() { return 3; } //! total number of input and output streams
				  static int flops() { return 5; }
				};
  
				double3 xpyHeavyQuarkResidualNorm(ColorSpinorField &x, ColorSpinorField &y,
								  ColorSpinorField &r) {
				  double3 rtn = reduce::reduceCuda<double3,QudaSumFloat3,QudaSumFloat,xpyHeavyQuarkResidualNorm_,0,0,0,0,0,true>
				    (make_double2(0.0, 0.0), make_double2(0.0, 0.0), x, y, r, r, r);
#ifdef MULTI_GPU
				  rtn.z /= (x.Volume()*comm_size());
#else
				  rtn.z /= x.Volume();
#endif
				  return rtn;
				}

#else
  
				double3 HeavyQuarkResidualNorm(ColorSpinorField &x, ColorSpinorField &r) {
				  errorQuda("Not supported on pre-Fermi architectures");
				  return make_double3(0.0,0.0,0.0);
				}

				double3 xpyHeavyQuarkResidualNorm(ColorSpinorField &x, ColorSpinorField &y,
								  ColorSpinorField &r) {
				  errorQuda("Not supported on pre-Fermi architectures");
				  return make_double3(0.0,0.0,0.0);
				}

#endif
    
				/**
				   double3 tripleCGUpdate(V x, V y, V z){}

				   First performs the operation norm2(x)
				   Second performs the operatio norm2(y)
				   Third performs the operation dotPropduct(y,z)
				*/

				template <typename ReduceType, typename Float2, typename FloatN>
#if (__COMPUTE_CAPABILITY__ >= 200)
				struct tripleCGReduction_ : public ReduceFunctor<ReduceType, Float2, FloatN> {
#else
				  struct tripleCGReduction_ {
#endif
				    tripleCGReduction_(const Float2 &a, const Float2 &b) { ; }
				    __device__ __host__ void operator()(ReduceType &sum, FloatN &x, FloatN &y, FloatN &z, FloatN &w, FloatN &v) 
				    { sum.x += _norm2(x); sum.y += _norm2(y); sum.z += _dot(y,z); }
				    static int streams() { return 3; } //! total number of input and output streams
				    static int flops() { return 6; } //! flops per element
				  };

				  double3 tripleCGReduction(ColorSpinorField &x, ColorSpinorField &y, ColorSpinorField &z) {
				    return reduce::reduceCuda<double3,QudaSumFloat3,QudaSumFloat,tripleCGReduction_,0,0,0,0,0,false>
				      (make_double2(0.0, 0.0), make_double2(0.0, 0.0), x, y, z, x, x);
				  }

				} // namespace blas
			      } // namespace quda
